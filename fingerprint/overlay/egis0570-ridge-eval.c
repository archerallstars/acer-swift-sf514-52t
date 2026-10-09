/*
 * Score two EgisTec 0570 PGM frames with the clean-room Gabor/NCC
 * matcher, or run a synthetic self-test that does not need the pad.
 *
 * Usage:
 *   sf514-egis0570-ridge-eval --self-test
 *   sf514-egis0570-ridge-eval probe.pgm gallery.pgm
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#define _POSIX_C_SOURCE 200809L

#include "egis0570-ridge.h"

#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* =============================================================================
 * CONFIGURATION
 * ============================================================================= */

/* Must match fingerprint/overlay/egis0570.h. */
static const int configured_frame_width_pixels = 114;
static const int configured_frame_height_pixels = 57;
static const double configured_match_threshold = 0.48;
static const double configured_minimum_present_mean = 18.0;
static const double configured_minimum_present_stddev = 7.0;

/* Synthetic ridge period used by --self-test (pixels). */
static const double configured_synthetic_ridge_period_pixels = 5.0;
static const double configured_synthetic_ridge_amplitude = 90.0;
static const double configured_synthetic_ridge_offset = 128.0;

/* Identical-frame NCC must stay this high. */
static const double configured_self_test_identical_minimum_score = 0.90;

/* Shifted copy of the same ridges must still clear the login threshold. */
static const int configured_self_test_shift_pixels = 4;

static const int configured_log_queue_capacity = 64;
static const int configured_file_io_queue_capacity = 8;

/* =============================================================================
 * LOGGER
 * ============================================================================= */

enum LogSeverity
{
  LOG_SEVERITY_INFO = 0,
  LOG_SEVERITY_ERROR = 1,
};

struct LogQueueEntry
{
  enum LogSeverity log_severity;
  char log_message[512];
};

static struct LogQueueEntry log_queue_entries[64];
static int log_queue_head_index = 0;
static int log_queue_tail_index = 0;
static int log_queue_count = 0;
static int log_queue_worker_should_stop = 0;
static pthread_mutex_t log_queue_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t log_queue_not_empty = PTHREAD_COND_INITIALIZER;
static pthread_cond_t log_queue_not_full = PTHREAD_COND_INITIALIZER;
static pthread_t log_queue_worker_thread;

/* =============================================================================
 * FILE I/O QUEUE — PGM reads for the two-file path
 * ============================================================================= */

struct FileIoReadJob
{
  char source_path[4096];
  uint8_t *frame_bytes;
  int read_failed;
};

static struct FileIoReadJob file_io_read_jobs[8];
static int file_io_queue_head_index = 0;
static int file_io_queue_tail_index = 0;
static int file_io_queue_count = 0;
static int file_io_queue_worker_should_stop = 0;
static pthread_mutex_t file_io_queue_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t file_io_queue_not_empty = PTHREAD_COND_INITIALIZER;
static pthread_cond_t file_io_queue_not_full = PTHREAD_COND_INITIALIZER;
static pthread_cond_t file_io_queue_job_done = PTHREAD_COND_INITIALIZER;
static pthread_t file_io_queue_worker_thread;
static int file_io_completed_job_count = 0;
static int file_io_expected_job_count = 0;

/* =============================================================================
 * LOCAL DATA — CLI
 * ============================================================================= */

static int selected_self_test = 0;
static char selected_probe_path[4096];
static char selected_gallery_path[4096];

struct SelfTestCase
{
  const char *case_name;
  double probe_angle_radians;
  double gallery_angle_radians;
  int probe_shift_x_pixels;
  int gallery_shift_x_pixels;
  double minimum_score;
  double maximum_score;
  int uses_score_window;
};

struct SelfTestWorkerArgument
{
  const struct SelfTestCase *self_test_case;
  int *case_failed;
};

/* Prototypes: helpers live below main (entry point exception). */
static int file_io_queue_enqueue_read (const char *source_path);
static void file_io_queue_start_worker (void);
static void file_io_queue_stop_worker (void);
static void file_io_queue_wait_for_expected_jobs (void);
static void *file_io_queue_worker (void *unused_argument);
static int frame_read_pgm_file (
  const char *source_path,
  uint8_t *frame_bytes
);
static void log_error (const char *log_message);
static void log_info (const char *log_message);
static void log_queue_enqueue (
  enum LogSeverity log_severity,
  const char *log_message
);
static void log_queue_start_worker (void);
static void log_queue_stop_worker (void);
static void *log_queue_worker (void *unused_argument);
static int path_parse_command_line (
  int argument_count,
  char **argument_values
);
static void path_print_usage (const char *program_name);
static int run_pgm_pair_match (void);
static int run_self_test (void);
static void *run_self_test_case_worker (void *worker_argument);
static void synthetic_fill_ridge_frame (
  uint8_t *frame_bytes,
  double ridge_angle_radians
);
static void synthetic_translate_frame (
  uint8_t *frame_bytes,
  int shift_x_pixels
);

/* =============================================================================
 * ENTRY POINT
 * ============================================================================= */

/*
 * Parse the CLI, then either score two PGM files or run the synthetic
 * matcher self-test. Returns 0 on success.
 */
int
main (
  int argument_count,
  char **argument_values
)
{
  int run_status;

  log_queue_start_worker ();
  if (path_parse_command_line (argument_count, argument_values) != 0)
    {
      log_queue_stop_worker ();
      return 1; /* bad CLI */
    }
  else if (selected_self_test != 0)
    {
      run_status = run_self_test ();
      log_queue_stop_worker ();
      return run_status; /* 0 when every synthetic case passed */
    }
  else
    {
      file_io_queue_start_worker ();
      run_status = run_pgm_pair_match ();
      file_io_queue_stop_worker ();
      log_queue_stop_worker ();
      return run_status; /* 0 when both files loaded and a score was printed */
    }
}

/* =============================================================================
 * FILE I/O QUEUE
 * ============================================================================= */

/*
 * Queue one PGM read. The worker fills frame_bytes on that job slot.
 * Returns 0 when the job was queued.
 */
static int
file_io_queue_enqueue_read (const char *source_path)
{
  pthread_mutex_lock (&file_io_queue_mutex);
  while (file_io_queue_count >= configured_file_io_queue_capacity
         && file_io_queue_worker_should_stop == 0)
    {
      pthread_cond_wait (&file_io_queue_not_full, &file_io_queue_mutex);
    }
  if (file_io_queue_worker_should_stop != 0)
    {
      pthread_mutex_unlock (&file_io_queue_mutex);
      return 1; /* worker is stopping */
    }
  else
    {
      struct FileIoReadJob *job = &file_io_read_jobs[file_io_queue_tail_index];
      memset (job, 0, sizeof (*job));
      snprintf (job->source_path, sizeof (job->source_path), "%s", source_path);
      job->frame_bytes = malloc (
        (size_t) configured_frame_width_pixels
        * (size_t) configured_frame_height_pixels);
      job->read_failed = 0;
      if (job->frame_bytes == NULL)
        {
          pthread_mutex_unlock (&file_io_queue_mutex);
          return 1; /* malloc failed */
        }
      else
        {
          file_io_queue_tail_index =
            (file_io_queue_tail_index + 1) % configured_file_io_queue_capacity;
          file_io_queue_count += 1;
          file_io_expected_job_count += 1;
          pthread_cond_signal (&file_io_queue_not_empty);
          pthread_mutex_unlock (&file_io_queue_mutex);
          return 0; /* job queued */
        }
    }
}

/*
 * Start the PGM-read worker thread with empty completion counters.
 */
static void
file_io_queue_start_worker (void)
{
  file_io_queue_worker_should_stop = 0;
  file_io_completed_job_count = 0;
  file_io_expected_job_count = 0;
  pthread_create (&file_io_queue_worker_thread, NULL, file_io_queue_worker, NULL);
}

/*
 * Ask the PGM-read worker to exit and join it.
 */
static void
file_io_queue_stop_worker (void)
{
  pthread_mutex_lock (&file_io_queue_mutex);
  file_io_queue_worker_should_stop = 1;
  pthread_cond_broadcast (&file_io_queue_not_empty);
  pthread_mutex_unlock (&file_io_queue_mutex);
  pthread_join (file_io_queue_worker_thread, NULL);
}

/*
 * Block until the worker has finished every job that was queued.
 */
static void
file_io_queue_wait_for_expected_jobs (void)
{
  pthread_mutex_lock (&file_io_queue_mutex);
  while (file_io_completed_job_count < file_io_expected_job_count)
    {
      pthread_cond_wait (&file_io_queue_job_done, &file_io_queue_mutex);
    }
  pthread_mutex_unlock (&file_io_queue_mutex);
}

/*
 * Drain queued PGM reads on a background thread.
 */
static void *
file_io_queue_worker (void *unused_argument)
{
  (void) unused_argument;
  for (;;)
    {
      struct FileIoReadJob *job;
      pthread_mutex_lock (&file_io_queue_mutex);
      while (file_io_queue_count == 0 && file_io_queue_worker_should_stop == 0)
        {
          pthread_cond_wait (&file_io_queue_not_empty, &file_io_queue_mutex);
        }
      if (file_io_queue_count == 0 && file_io_queue_worker_should_stop != 0)
        {
          pthread_mutex_unlock (&file_io_queue_mutex);
          return NULL; /* shutdown with an empty queue */
        }
      else
        {
          job = &file_io_read_jobs[file_io_queue_head_index];
          pthread_mutex_unlock (&file_io_queue_mutex);
          if (frame_read_pgm_file (job->source_path, job->frame_bytes) != 0)
            {
              job->read_failed = 1;
            }
          else
            {
              job->read_failed = 0;
            }
          pthread_mutex_lock (&file_io_queue_mutex);
          file_io_queue_head_index =
            (file_io_queue_head_index + 1) % configured_file_io_queue_capacity;
          file_io_queue_count -= 1;
          file_io_completed_job_count += 1;
          pthread_cond_signal (&file_io_queue_not_full);
          pthread_cond_signal (&file_io_queue_job_done);
          pthread_mutex_unlock (&file_io_queue_mutex);
        }
    }
}

/* =============================================================================
 * PGM
 * ============================================================================= */

/*
 * Read a P5 PGM written by the capture tool (114 by 57, maxval 255)
 * into frame_bytes. Returns 0 on success.
 */
static int
frame_read_pgm_file (
  const char *source_path,
  uint8_t *frame_bytes
)
{
  FILE *pgm_file;
  char magic[3];
  int width_pixels = 0;
  int height_pixels = 0;
  int maximum_value = 0;
  size_t pixel_count;
  size_t bytes_read;

  pgm_file = fopen (source_path, "rb");
  if (pgm_file == NULL)
    {
      return 1; /* cannot open */
    }
  else
    {
      if (fscanf (pgm_file, "%2s", magic) != 1)
        {
          fclose (pgm_file);
          return 1; /* missing magic */
        }
      else if (strcmp (magic, "P5") != 0)
        {
          fclose (pgm_file);
          return 1; /* not a binary PGM */
        }
      else if (fscanf (
                 pgm_file,
                 "%d %d %d",
                 &width_pixels,
                 &height_pixels,
                 &maximum_value) != 3)
        {
          fclose (pgm_file);
          return 1; /* header numbers missing */
        }
      else if (width_pixels != configured_frame_width_pixels
               || height_pixels != configured_frame_height_pixels
               || maximum_value != 255)
        {
          fclose (pgm_file);
          return 1; /* unexpected geometry */
        }
      else
        {
          int next_byte = fgetc (pgm_file);
          if (next_byte != '\n' && next_byte != ' ' && next_byte != '\r')
            {
              if (next_byte != EOF)
                {
                  ungetc (next_byte, pgm_file);
                }
              else
                {
                  fclose (pgm_file);
                  return 1; /* truncated after header */
                }
            }
          else
            {
              /* whitespace after maxval consumed */
            }
          pixel_count =
            (size_t) configured_frame_width_pixels
            * (size_t) configured_frame_height_pixels;
          bytes_read = fread (frame_bytes, 1, pixel_count, pgm_file);
          fclose (pgm_file);
          if (bytes_read != pixel_count)
            {
              return 1; /* short pixel payload */
            }
          else
            {
              return 0; /* frame_bytes filled */
            }
        }
    }
}

/* =============================================================================
 * LOGGER
 * ============================================================================= */

/*
 * Queue one error line for the log worker.
 */
static void
log_error (const char *log_message)
{
  log_queue_enqueue (LOG_SEVERITY_ERROR, log_message);
}

/*
 * Queue one informational line for the log worker.
 */
static void
log_info (const char *log_message)
{
  log_queue_enqueue (LOG_SEVERITY_INFO, log_message);
}

/*
 * Push one log line onto the bounded log queue.
 */
static void
log_queue_enqueue (
  enum LogSeverity log_severity,
  const char *log_message
)
{
  pthread_mutex_lock (&log_queue_mutex);
  while (log_queue_count >= configured_log_queue_capacity)
    {
      pthread_cond_wait (&log_queue_not_full, &log_queue_mutex);
    }
  log_queue_entries[log_queue_tail_index].log_severity = log_severity;
  snprintf (
    log_queue_entries[log_queue_tail_index].log_message,
    sizeof (log_queue_entries[log_queue_tail_index].log_message),
    "%s",
    log_message);
  log_queue_tail_index = (log_queue_tail_index + 1) % configured_log_queue_capacity;
  log_queue_count += 1;
  pthread_cond_signal (&log_queue_not_empty);
  pthread_mutex_unlock (&log_queue_mutex);
}

/*
 * Start the thread that prints queued log lines.
 */
static void
log_queue_start_worker (void)
{
  log_queue_worker_should_stop = 0;
  pthread_create (&log_queue_worker_thread, NULL, log_queue_worker, NULL);
}

/*
 * Ask the log worker to exit and join it.
 */
static void
log_queue_stop_worker (void)
{
  pthread_mutex_lock (&log_queue_mutex);
  log_queue_worker_should_stop = 1;
  pthread_cond_broadcast (&log_queue_not_empty);
  pthread_mutex_unlock (&log_queue_mutex);
  pthread_join (log_queue_worker_thread, NULL);
}

/*
 * Drain the log queue to stdout (info) or stderr (error).
 */
static void *
log_queue_worker (void *unused_argument)
{
  (void) unused_argument;
  for (;;)
    {
      struct LogQueueEntry entry;
      pthread_mutex_lock (&log_queue_mutex);
      while (log_queue_count == 0 && log_queue_worker_should_stop == 0)
        {
          pthread_cond_wait (&log_queue_not_empty, &log_queue_mutex);
        }
      if (log_queue_count == 0 && log_queue_worker_should_stop != 0)
        {
          pthread_mutex_unlock (&log_queue_mutex);
          return NULL; /* shutdown */
        }
      else
        {
          entry = log_queue_entries[log_queue_head_index];
          log_queue_head_index =
            (log_queue_head_index + 1) % configured_log_queue_capacity;
          log_queue_count -= 1;
          pthread_cond_signal (&log_queue_not_full);
          pthread_mutex_unlock (&log_queue_mutex);
          if (entry.log_severity == LOG_SEVERITY_ERROR)
            {
              fprintf (stderr, "sf514-egis0570-ridge-eval: %s\n", entry.log_message);
            }
          else
            {
              fprintf (stdout, "sf514-egis0570-ridge-eval: %s\n", entry.log_message);
            }
        }
    }
}

/* =============================================================================
 * CLI
 * ============================================================================= */

/*
 * Print CLI help to stdout.
 */
static void
path_print_usage (const char *program_name)
{
  printf (
    "Usage: %s --self-test\n"
    "       %s probe.pgm gallery.pgm\n"
    "Score 114x57 PGM frames with the overlay Gabor/NCC matcher.\n",
    program_name,
    program_name);
}

/*
 * Accept --self-test or two PGM paths. Returns 0 when the run can
 * continue, 1 when the invocation is help or invalid.
 */
static int
path_parse_command_line (
  int argument_count,
  char **argument_values
)
{
  selected_self_test = 0;
  selected_probe_path[0] = '\0';
  selected_gallery_path[0] = '\0';
  if (argument_count == 2 && strcmp (argument_values[1], "--self-test") == 0)
    {
      selected_self_test = 1;
      return 0; /* self-test requested */
    }
  else if (argument_count == 2
           && (strcmp (argument_values[1], "--help") == 0
               || strcmp (argument_values[1], "-h") == 0))
    {
      path_print_usage (argument_values[0]);
      return 1; /* help is not a scoring run */
    }
  else if (argument_count == 3)
    {
      snprintf (selected_probe_path, sizeof (selected_probe_path), "%s", argument_values[1]);
      snprintf (selected_gallery_path, sizeof (selected_gallery_path), "%s", argument_values[2]);
      return 0; /* two PGM paths */
    }
  else
    {
      path_print_usage (argument_values[0]);
      return 1; /* unknown invocation */
    }
}

/* =============================================================================
 * MATCH
 * ============================================================================= */

/*
 * Load probe.pgm and gallery.pgm through the file queue and print the
 * NCC score plus whether it meets the login threshold. Returns 0 when
 * both files loaded.
 */
static int
run_pgm_pair_match (void)
{
  double score;
  char score_message[256];
  uint8_t *probe_bytes;
  uint8_t *gallery_bytes;

  if (file_io_queue_enqueue_read (selected_probe_path) != 0
      || file_io_queue_enqueue_read (selected_gallery_path) != 0)
    {
      log_error ("Could not queue PGM reads");
      return 1; /* queue rejected a job */
    }
  else
    {
      file_io_queue_wait_for_expected_jobs ();
    }

  if (file_io_read_jobs[0].read_failed != 0)
    {
      log_error ("Could not read the probe PGM (need a 114x57 P5 file)");
      free (file_io_read_jobs[0].frame_bytes);
      free (file_io_read_jobs[1].frame_bytes);
      return 1; /* probe missing or wrong size */
    }
  else if (file_io_read_jobs[1].read_failed != 0)
    {
      log_error ("Could not read the gallery PGM (need a 114x57 P5 file)");
      free (file_io_read_jobs[0].frame_bytes);
      free (file_io_read_jobs[1].frame_bytes);
      return 1; /* gallery missing or wrong size */
    }
  else
    {
      probe_bytes = file_io_read_jobs[0].frame_bytes;
      gallery_bytes = file_io_read_jobs[1].frame_bytes;
      score = egis0570_ridge_match_score (
        probe_bytes,
        gallery_bytes,
        configured_frame_width_pixels,
        configured_frame_height_pixels);
      snprintf (
        score_message,
        sizeof (score_message),
        "score=%.4f threshold=%.2f %s",
        score,
        configured_match_threshold,
        (score >= configured_match_threshold) ? "ACCEPT" : "REJECT");
      log_info (score_message);
      free (probe_bytes);
      free (gallery_bytes);
      return 0; /* score printed */
    }
}

/*
 * Fill frame_bytes with a period-5 sinusoid at ridge_angle_radians,
 * with a circular envelope so the pattern looks like a small pad
 * press rather than a full-frame grating.
 */
static void
synthetic_fill_ridge_frame (
  uint8_t *frame_bytes,
  double ridge_angle_radians
)
{
  int pixel_x;
  int pixel_y;
  double cosine_value = cos (ridge_angle_radians);
  double sine_value = sin (ridge_angle_radians);
  double center_x = ((double) configured_frame_width_pixels - 1.0) / 2.0;
  double center_y = ((double) configured_frame_height_pixels - 1.0) / 2.0;
  double envelope_radius = (double) configured_frame_height_pixels * 0.45;

  for (pixel_y = 0; pixel_y < configured_frame_height_pixels; pixel_y++)
    {
      for (pixel_x = 0; pixel_x < configured_frame_width_pixels; pixel_x++)
        {
          double relative_x = (double) pixel_x - center_x;
          double relative_y = (double) pixel_y - center_y;
          double ridge_coordinate =
            relative_x * cosine_value + relative_y * sine_value;
          double radius = sqrt (relative_x * relative_x + relative_y * relative_y);
          double envelope;
          double intensity;
          int pixel_value;
          if (radius >= envelope_radius)
            {
              envelope = 0.0;
            }
          else
            {
              envelope = 0.5 * (1.0 + cos (M_PI * radius / envelope_radius));
            }
          intensity =
            configured_synthetic_ridge_offset
            + envelope
              * configured_synthetic_ridge_amplitude
              * sin (
                  2.0 * M_PI * ridge_coordinate
                  / configured_synthetic_ridge_period_pixels);
          pixel_value = (int) floor (intensity + 0.5);
          if (pixel_value < 0)
            {
              pixel_value = 0;
            }
          else if (pixel_value > 255)
            {
              pixel_value = 255;
            }
          else
            {
              /* already in range */
            }
          frame_bytes[pixel_y * configured_frame_width_pixels + pixel_x] =
            (uint8_t) pixel_value;
        }
    }
}

/*
 * Translate frame_bytes by shift_x_pixels (positive = content moves
 * right). Vacated columns are filled with the sinusoid offset so the
 * matcher sees a pad-sized translation, not a wrap-around.
 */
static void
synthetic_translate_frame (
  uint8_t *frame_bytes,
  int shift_x_pixels
)
{
  int pixel_count =
    configured_frame_width_pixels * configured_frame_height_pixels;
  uint8_t *scratch_bytes = malloc ((size_t) pixel_count);
  int pixel_x;
  int pixel_y;
  uint8_t fill_value = (uint8_t) configured_synthetic_ridge_offset;

  if (scratch_bytes == NULL)
    {
      return; /* leave the frame unshifted */
    }
  else
    {
      memcpy (scratch_bytes, frame_bytes, (size_t) pixel_count);
      for (pixel_y = 0; pixel_y < configured_frame_height_pixels; pixel_y++)
        {
          for (pixel_x = 0; pixel_x < configured_frame_width_pixels; pixel_x++)
            {
              int source_x = pixel_x - shift_x_pixels;
              if (source_x < 0 || source_x >= configured_frame_width_pixels)
                {
                  frame_bytes[pixel_y * configured_frame_width_pixels + pixel_x] =
                    fill_value;
                }
              else
                {
                  frame_bytes[pixel_y * configured_frame_width_pixels + pixel_x] =
                    scratch_bytes[pixel_y * configured_frame_width_pixels + source_x];
                }
            }
        }
      free (scratch_bytes);
    }
}

/*
 * Run one synthetic matcher case. Writes 0 into case_failed on pass.
 */
static void *
run_self_test_case_worker (void *worker_argument)
{
  struct SelfTestWorkerArgument *argument =
    (struct SelfTestWorkerArgument *) worker_argument;
  const struct SelfTestCase *self_test_case = argument->self_test_case;
  int pixel_count =
    configured_frame_width_pixels * configured_frame_height_pixels;
  uint8_t *probe_bytes = malloc ((size_t) pixel_count);
  uint8_t *gallery_bytes = malloc ((size_t) pixel_count);
  double score;
  char result_message[256];

  if (probe_bytes == NULL || gallery_bytes == NULL)
    {
      log_error ("Out of memory in a self-test case");
      *(argument->case_failed) = 1;
      free (probe_bytes);
      free (gallery_bytes);
      return NULL; /* malloc failed */
    }
  else
    {
      synthetic_fill_ridge_frame (
        probe_bytes,
        self_test_case->probe_angle_radians);
      synthetic_fill_ridge_frame (
        gallery_bytes,
        self_test_case->gallery_angle_radians);
      if (self_test_case->probe_shift_x_pixels != 0)
        {
          synthetic_translate_frame (
            probe_bytes,
            self_test_case->probe_shift_x_pixels);
        }
      else
        {
          /* probe stays centred */
        }
      if (self_test_case->gallery_shift_x_pixels != 0)
        {
          synthetic_translate_frame (
            gallery_bytes,
            self_test_case->gallery_shift_x_pixels);
        }
      else
        {
          /* gallery stays centred */
        }
      score = egis0570_ridge_match_score (
        probe_bytes,
        gallery_bytes,
        configured_frame_width_pixels,
        configured_frame_height_pixels);
      if (self_test_case->uses_score_window != 0
          && (score < self_test_case->minimum_score
              || score > self_test_case->maximum_score))
        {
          snprintf (
            result_message,
            sizeof (result_message),
            "FAIL %s score=%.4f (want %.2f .. %.2f)",
            self_test_case->case_name,
            score,
            self_test_case->minimum_score,
            self_test_case->maximum_score);
          log_error (result_message);
          *(argument->case_failed) = 1;
        }
      else if (self_test_case->uses_score_window == 0
               && score < self_test_case->minimum_score)
        {
          snprintf (
            result_message,
            sizeof (result_message),
            "FAIL %s score=%.4f (want >= %.2f)",
            self_test_case->case_name,
            score,
            self_test_case->minimum_score);
          log_error (result_message);
          *(argument->case_failed) = 1;
        }
      else
        {
          snprintf (
            result_message,
            sizeof (result_message),
            "PASS %s score=%.4f",
            self_test_case->case_name,
            score);
          log_info (result_message);
          *(argument->case_failed) = 0;
        }
      free (probe_bytes);
      free (gallery_bytes);
      return NULL; /* case finished */
    }
}

/*
 * Check finger-present on synthetic empty vs ridge frames, then run
 * matcher cases in parallel. Returns 0 when every case passed.
 */
static int
run_self_test (void)
{
  int pixel_count =
    configured_frame_width_pixels * configured_frame_height_pixels;
  uint8_t *empty_bytes = malloc ((size_t) pixel_count);
  uint8_t *ridge_bytes = malloc ((size_t) pixel_count);
  uint8_t *dark_background_bytes = malloc ((size_t) pixel_count);
  int present_on_empty;
  int present_on_ridge;
  int failed_count = 0;
  char present_message[256];
  const struct SelfTestCase self_test_cases[] = {
    {
      "identical-vertical",
      0.0,
      0.0,
      0,
      0,
      configured_self_test_identical_minimum_score,
      1.0,
      0,
    },
    {
      "vertical-shifted-4px",
      0.0,
      0.0,
      configured_self_test_shift_pixels,
      0,
      configured_match_threshold,
      1.0,
      0,
    },
    {
      "vertical-vs-horizontal",
      0.0,
      M_PI / 2.0,
      0,
      0,
      -1.0,
      configured_match_threshold,
      1,
    },
  };
  const int self_test_case_count =
    (int) (sizeof (self_test_cases) / sizeof (self_test_cases[0]));
  struct SelfTestWorkerArgument worker_arguments[3];
  pthread_t worker_threads[3];
  int case_failed[3];
  int case_index;
  int thread_started[3];

  if (empty_bytes == NULL || ridge_bytes == NULL || dark_background_bytes == NULL)
    {
      log_error ("Out of memory for finger-present fixtures");
      free (empty_bytes);
      free (ridge_bytes);
      free (dark_background_bytes);
      return 1; /* malloc failed */
    }
  else
    {
      memset (empty_bytes, 30, (size_t) pixel_count);
      memset (dark_background_bytes, 10, (size_t) pixel_count);
      synthetic_fill_ridge_frame (ridge_bytes, 0.0);
      present_on_empty = egis0570_ridge_finger_present (
        empty_bytes,
        empty_bytes,
        pixel_count,
        configured_minimum_present_mean,
        configured_minimum_present_stddev);
      present_on_ridge = egis0570_ridge_finger_present (
        ridge_bytes,
        dark_background_bytes,
        pixel_count,
        configured_minimum_present_mean,
        configured_minimum_present_stddev);
      if (present_on_empty != 0)
        {
          log_error ("FAIL finger-present: empty-minus-empty was treated as a finger");
          failed_count += 1;
        }
      else
        {
          log_info ("PASS finger-present empty-minus-empty is absent");
        }
      if (present_on_ridge == 0)
        {
          log_error ("FAIL finger-present: ridge-minus-dark was treated as empty");
          failed_count += 1;
        }
      else
        {
          snprintf (
            present_message,
            sizeof (present_message),
            "PASS finger-present ridge-minus-dark is present");
          log_info (present_message);
        }
      free (empty_bytes);
      free (ridge_bytes);
      free (dark_background_bytes);
    }

  for (case_index = 0; case_index < self_test_case_count; case_index++)
    {
      worker_arguments[case_index].self_test_case = &self_test_cases[case_index];
      worker_arguments[case_index].case_failed = &case_failed[case_index];
      case_failed[case_index] = 1;
      if (pthread_create (
            &worker_threads[case_index],
            NULL,
            run_self_test_case_worker,
            &worker_arguments[case_index]) != 0)
        {
          run_self_test_case_worker (&worker_arguments[case_index]);
          thread_started[case_index] = 0;
        }
      else
        {
          thread_started[case_index] = 1;
        }
    }

  for (case_index = 0; case_index < self_test_case_count; case_index++)
    {
      if (thread_started[case_index] != 0)
        {
          pthread_join (worker_threads[case_index], NULL);
        }
      else
        {
          /* ran on this thread already */
        }
      if (case_failed[case_index] != 0)
        {
          failed_count += 1;
        }
      else
        {
          /* case passed */
        }
    }

  if (failed_count != 0)
    {
      char summary_message[128];
      snprintf (
        summary_message,
        sizeof (summary_message),
        "Self-test failed (%d checks)",
        failed_count);
      log_error (summary_message);
      return 1; /* at least one check failed */
    }
  else
    {
      log_info ("Self-test passed");
      return 0; /* every check passed */
    }
}
