/*
 * Capture raw frames from the EgisTec 1c7a:0570 pad on this laptop.
 *
 * Sends an EGIS/SIGE init and repeat sequence over libusb, dumps each
 * 114 by 57 subframe as PGM, and records mean / stddev so we can tell
 * empty, washed-out, and finger-held captures apart.
 *
 * --init stock uses in-tree libfprint packets. --init windows (default)
 * uses the tmullender/egis-eh570 Windows-derived list. --wait pauses until
 * Enter so a finger can already be on the pad.
 *
 * If the USB interface is busy, stop fprintd on the host first:
 *   sudo systemctl stop fprintd.service
 *
 * Live dumps are fingerprint images. The output directory is mode 0700
 * and each PGM is mode 0600. Delete them when diagnosis is done.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include "sf514_egis0570_protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <libusb.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* =============================================================================
 * CONFIGURATION
 * ============================================================================= */

/* --- USB identity (overridable only by rebuilding; this chassis is 0570) --- */
static const uint16_t configured_usb_vendor_id = SF514_EGIS0570_USB_VENDOR_ID;
static const uint16_t configured_usb_product_id = SF514_EGIS0570_USB_PRODUCT_ID;
static const int configured_usb_interface_number = SF514_EGIS0570_USB_INTERFACE_NUMBER;
static const unsigned char configured_bulk_out_endpoint = SF514_EGIS0570_USB_BULK_OUT_ENDPOINT;
static const unsigned char configured_bulk_in_endpoint = SF514_EGIS0570_USB_BULK_IN_ENDPOINT;
static const unsigned int configured_transfer_timeout_milliseconds =
  SF514_EGIS0570_TRANSFER_TIMEOUT_MILLISECONDS;

/* --- Capture geometry --- */
static const int configured_command_packet_size_bytes = SF514_EGIS0570_COMMAND_PACKET_SIZE_BYTES;
static const int configured_capture_payload_size_bytes = SF514_EGIS0570_CAPTURE_PAYLOAD_SIZE_BYTES;
static const int configured_frame_width_pixels = SF514_EGIS0570_FRAME_WIDTH_PIXELS;
static const int configured_frame_height_pixels = SF514_EGIS0570_FRAME_HEIGHT_PIXELS;
static const int configured_frame_size_bytes = SF514_EGIS0570_FRAME_SIZE_BYTES;
static const int configured_frame_count_per_capture = SF514_EGIS0570_FRAME_COUNT_PER_CAPTURE;

/* --- Frame quality gates used in the stats text --- */
static const double configured_all_zero_mean_ceiling = 1.0;
static const double configured_washed_out_stddev_ceiling = 3.0;
static const int configured_saturated_pixel_floor = 250;

/* --- CLI defaults (path_parse_command_line may overwrite the mutable copies) --- */
static const char *configured_default_output_directory = "fingerprint/captures";
static const char *configured_default_capture_label = "empty";
static const int configured_default_burst_count = 1;
/* 0 = capture as soon as the pad is claimed. */
static const int configured_default_wait_for_operator = 0;
static const int configured_file_io_queue_capacity = 256;
static const int configured_log_queue_capacity = 256;
/* Pause after the log queue is empty so the Enter prompt is not buried. */
static const int configured_log_drain_settle_microseconds = 20000;
/*
 * Live pad dumps can contain fingerprint images. The leaf output
 * directory is owner-only. Intermediate parents stay 0755 so a
 * dump under an existing repo tree still works. Each PGM is 0600.
 */
static const mode_t configured_capture_parent_directory_mode = 0755;
static const mode_t configured_capture_directory_mode = 0700;
static const mode_t configured_capture_file_mode = 0600;

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

static struct LogQueueEntry log_queue_entries[256];
static int log_queue_head_index = 0;
static int log_queue_tail_index = 0;
static int log_queue_count = 0;
static int log_queue_worker_should_stop = 0;
static pthread_mutex_t log_queue_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t log_queue_not_empty = PTHREAD_COND_INITIALIZER;
static pthread_cond_t log_queue_not_full = PTHREAD_COND_INITIALIZER;
static pthread_t log_queue_worker_thread;

/* =============================================================================
 * LOCAL DATA — EGIS/SIGE command sequences
 * ============================================================================= */

/*
 * Which 7-byte init list burst 0 sends. Stock is in-tree libfprint
 * egis0570. Windows is tmullender/egis-eh570 demo.c (same USB PID,
 * derived from the Windows driver). Repeat packets are shared.
 */
enum ProtocolInitializationKind
{
  PROTOCOL_INITIALIZATION_KIND_STOCK = 0,
  PROTOCOL_INITIALIZATION_KIND_WINDOWS = 1,
};

/* Default is windows: stock empty vs finger dumps on this pad were identical. */
static const enum ProtocolInitializationKind configured_default_initialization_kind =
  PROTOCOL_INITIALIZATION_KIND_WINDOWS;

static const unsigned char protocol_stock_initialization_packets[][SF514_EGIS0570_COMMAND_PACKET_SIZE_BYTES] =
{
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x20, 0x3f },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x58, 0x3f },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x21, 0x09 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x57, 0x09 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x22, 0x03 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x56, 0x03 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x23, 0x01 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x55, 0x01 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x24, 0x01 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x54, 0x01 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x16, 0x3e },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x09, 0x0b },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x14, 0x03 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x15, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x02, 0x0f },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x10, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x11, 0x38 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x12, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x13, 0x71 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x03, 0x80 },
  { 0x45, 0x47, 0x49, 0x53, 0x00, 0x02, 0x80 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x02, 0x2f },
  { 0x45, 0x47, 0x49, 0x53, 0x06, 0x00, 0xfe },
};

static const unsigned char protocol_windows_initialization_packets[][SF514_EGIS0570_COMMAND_PACKET_SIZE_BYTES] =
{
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x0d, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x0e, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x02, 0x1f },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x05, 0x08 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x03, 0xff },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x10, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x11, 0x38 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x12, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x13, 0x71 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x20, 0x41 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x58, 0x41 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x21, 0x09 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x57, 0x09 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x22, 0x02 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x56, 0x02 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x23, 0x01 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x55, 0x01 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x24, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x54, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x25, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x53, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x15, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x16, 0x41 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x09, 0x0a },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x14, 0x00 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x02, 0x0f },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x03, 0x80 },
  { 0x45, 0x47, 0x49, 0x53, 0x00, 0x02, 0x80 },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x02, 0x2f },
  { 0x45, 0x47, 0x49, 0x53, 0x06, 0x00, 0xfe },
};

static const unsigned char protocol_repeat_packets[][SF514_EGIS0570_COMMAND_PACKET_SIZE_BYTES] =
{
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x02, 0x0f },
  { 0x45, 0x47, 0x49, 0x53, 0x00, 0x02, 0x0f },
  { 0x45, 0x47, 0x49, 0x53, 0x01, 0x02, 0x2f },
  { 0x45, 0x47, 0x49, 0x53, 0x06, 0x00, 0xfe },
};

static const int protocol_stock_initialization_packet_count =
  (int) (sizeof (protocol_stock_initialization_packets)
         / sizeof (protocol_stock_initialization_packets[0]));
static const int protocol_windows_initialization_packet_count =
  (int) (sizeof (protocol_windows_initialization_packets)
         / sizeof (protocol_windows_initialization_packets[0]));
static const int protocol_repeat_packet_count =
  (int) (sizeof (protocol_repeat_packets) / sizeof (protocol_repeat_packets[0]));

/* =============================================================================
 * FILE I/O QUEUE
 * ============================================================================= */

enum FileIoJobKind
{
  FILE_IO_JOB_KIND_CREATE_DIRECTORY = 0,
  FILE_IO_JOB_KIND_WRITE_FILE = 1,
};

struct FileIoQueueJob
{
  enum FileIoJobKind job_kind;
  char destination_path[4096];
  unsigned char *payload_bytes;
  size_t payload_size_bytes;
};

static struct FileIoQueueJob file_io_queue_jobs[256];
static int file_io_queue_head_index = 0;
static int file_io_queue_tail_index = 0;
static int file_io_queue_count = 0;
static int file_io_queue_failed_job_count = 0;
static int file_io_queue_worker_should_stop = 0;
static pthread_mutex_t file_io_queue_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t file_io_queue_not_empty = PTHREAD_COND_INITIALIZER;
static pthread_cond_t file_io_queue_not_full = PTHREAD_COND_INITIALIZER;
static pthread_t file_io_queue_worker_thread;

/* Mutable CLI state filled before capture starts. */
static char selected_output_directory[4096];
static char selected_capture_label[64];
static int selected_burst_count = 1;
static int selected_wait_for_operator = 0;
static enum ProtocolInitializationKind selected_initialization_kind =
  PROTOCOL_INITIALIZATION_KIND_WINDOWS;

struct FrameStatistics
{
  double mean_value;
  double standard_deviation;
  int minimum_value;
  int maximum_value;
  int zero_pixel_count;
  int saturated_pixel_count;
  int is_all_zero;
  int is_washed_out;
};

struct FrameStatisticsWorkerArgument
{
  const unsigned char *frame_bytes;
  struct FrameStatistics *frame_statistics;
};

/* Prototypes: helpers live below main (entry point exception). */
static const char *capture_initialization_kind_name (
  enum ProtocolInitializationKind initialization_kind
);
static int capture_run_all_bursts (libusb_device_handle *device_handle);
static int capture_run_one_burst (
  libusb_device_handle *device_handle,
  int burst_index,
  int use_initialization_sequence
);
static void file_io_queue_drain (void);
static int file_io_queue_enqueue (
  enum FileIoJobKind job_kind,
  const char *destination_path,
  unsigned char *payload_bytes,
  size_t payload_size_bytes
);
static void file_io_queue_start_worker (void);
static void file_io_queue_stop_worker (void);
static void *file_io_queue_worker (void *unused_argument);
static unsigned char *frame_build_pgm_bytes (
  const unsigned char *frame_bytes,
  size_t *pgm_size_bytes
);
static void frame_compute_statistics (
  const unsigned char *frame_bytes,
  struct FrameStatistics *frame_statistics
);
static void *frame_compute_statistics_worker (void *worker_argument);
static char *frame_statistics_to_text (
  int burst_index,
  const struct FrameStatistics *frame_statistics_list
);
static void log_error (const char *log_message);
static void log_info (const char *log_message);
static void log_queue_drain (void);
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
static void path_wait_for_operator_ready (void);
static int usb_claim_sensor (
  libusb_context **usb_context,
  libusb_device_handle **device_handle
);
static void usb_log_open_failure (
  int libusb_status,
  int matching_device_count
);
static void usb_close_sensor (
  libusb_context *usb_context,
  libusb_device_handle *device_handle
);
static int usb_describe_sensor (libusb_device_handle *device_handle);
static int usb_read_bulk (
  libusb_device_handle *device_handle,
  unsigned char *buffer_bytes,
  int buffer_size_bytes,
  int *actual_length_bytes
);
static int usb_send_command_expect_ack (
  libusb_device_handle *device_handle,
  const unsigned char *command_packet
);
static int usb_send_command_expect_image (
  libusb_device_handle *device_handle,
  const unsigned char *command_packet,
  unsigned char *capture_payload_bytes
);
static int usb_send_packet_sequence (
  libusb_device_handle *device_handle,
  const unsigned char packets[][SF514_EGIS0570_COMMAND_PACKET_SIZE_BYTES],
  int packet_count,
  unsigned char *capture_payload_bytes
);
static int usb_write_bulk (
  libusb_device_handle *device_handle,
  const unsigned char *buffer_bytes,
  int buffer_size_bytes
);

/* =============================================================================
 * ENTRY POINT
 * ============================================================================= */

/*
 * Open the pad, run init plus the requested number of image bursts, and
 * write PGM plus stats under the output directory. Returns 0 on success.
 */
int
main (
  int argument_count,
  char **argument_values
)
{
  libusb_context *usb_context = NULL;
  libusb_device_handle *device_handle = NULL;
  int capture_status;

  log_queue_start_worker ();
  file_io_queue_start_worker ();

  if (path_parse_command_line (argument_count, argument_values) != 0)
    {
      log_queue_stop_worker ();
      file_io_queue_stop_worker ();
      return 1; /* bad CLI */
    }
  else
    {
      if (file_io_queue_enqueue (
            FILE_IO_JOB_KIND_CREATE_DIRECTORY,
            selected_output_directory,
            NULL,
            0) != 0)
        {
          log_error ("Could not queue output directory creation");
          log_queue_stop_worker ();
          file_io_queue_stop_worker ();
          return 1; /* queue rejected the mkdir job */
        }
      else
        {
          file_io_queue_drain ();
        }
    }

  if (usb_claim_sensor (&usb_context, &device_handle) != 0)
    {
      log_queue_stop_worker ();
      file_io_queue_stop_worker ();
      return 1; /* pad missing or claimed by fprintd */
    }
  else
    {
      if (usb_describe_sensor (device_handle) != 0)
        {
          log_error ("Opened the pad but could not read USB descriptors");
        }
      else
        {
          log_info ("USB descriptors recorded");
        }
      if (selected_wait_for_operator != 0)
        {
          path_wait_for_operator_ready ();
        }
      else
        {
          /* capture starts as soon as the pad is claimed */
        }
      capture_status = capture_run_all_bursts (device_handle);
      usb_close_sensor (usb_context, device_handle);
      file_io_queue_drain ();
      log_queue_stop_worker ();
      file_io_queue_stop_worker ();
      if (capture_status != 0)
        {
          return 1; /* a burst failed */
        }
      else
        {
          return 0; /* every burst dumped */
        }
    }
}

/* =============================================================================
 * CAPTURE
 * ============================================================================= */

/*
 * Return the CLI name of initialization_kind ("stock" or "windows").
 */
static const char *
capture_initialization_kind_name (
  enum ProtocolInitializationKind initialization_kind
)
{
  if (initialization_kind == PROTOCOL_INITIALIZATION_KIND_STOCK)
    {
      return "stock"; /* in-tree libfprint egis0570 init */
    }
  else
    {
      return "windows"; /* tmullender/egis-eh570 Windows-derived init */
    }
}

/*
 * Run the init sequence for burst 0, then repeat sequences for later
 * bursts. Inputs: claimed device_handle. Returns 0 when every burst
 * wrote frames.
 */
static int
capture_run_all_bursts (libusb_device_handle *device_handle)
{
  int burst_index;
  int failed_burst_count = 0;
  char progress_message[256];
  int initialization_packet_count;
  const char *initialization_kind_name;

  initialization_kind_name =
    capture_initialization_kind_name (selected_initialization_kind);
  if (selected_initialization_kind == PROTOCOL_INITIALIZATION_KIND_STOCK)
    {
      initialization_packet_count = protocol_stock_initialization_packet_count;
    }
  else
    {
      initialization_packet_count = protocol_windows_initialization_packet_count;
    }
  snprintf (
    progress_message,
    sizeof (progress_message),
    "Using %s init (%d packets, last is capture 06 00 fe)",
    initialization_kind_name,
    initialization_packet_count);
  log_info (progress_message);

  for (burst_index = 0; burst_index < selected_burst_count; burst_index++)
    {
      int use_initialization_sequence;
      int burst_status;
      if (burst_index == 0)
        {
          use_initialization_sequence = 1;
        }
      else
        {
          use_initialization_sequence = 0;
        }
      snprintf (
        progress_message,
        sizeof (progress_message),
        "Starting burst %d of %d (label %s)",
        burst_index,
        selected_burst_count,
        selected_capture_label);
      log_info (progress_message);
      burst_status = capture_run_one_burst (
        device_handle,
        burst_index,
        use_initialization_sequence);
      if (burst_status != 0)
        {
          failed_burst_count += 1;
        }
      else
        {
          /* burst wrote PGM and stats */
        }
    }

  if (failed_burst_count != 0)
    {
      return 1; /* at least one burst failed */
    }
  else
    {
      return 0; /* all bursts succeeded */
    }
}

/*
 * Send init or repeat packets, split the 32512-byte payload into five
 * frames, compute stats in parallel, and queue PGM plus a stats text
 * file. Returns 0 on success.
 */
static int
capture_run_one_burst (
  libusb_device_handle *device_handle,
  int burst_index,
  int use_initialization_sequence
)
{
  unsigned char *capture_payload_bytes;
  struct FrameStatistics frame_statistics_list[SF514_EGIS0570_FRAME_COUNT_PER_CAPTURE];
  struct FrameStatisticsWorkerArgument worker_arguments[SF514_EGIS0570_FRAME_COUNT_PER_CAPTURE];
  pthread_t statistics_threads[SF514_EGIS0570_FRAME_COUNT_PER_CAPTURE];
  int statistics_thread_started[SF514_EGIS0570_FRAME_COUNT_PER_CAPTURE];
  int frame_index;
  int sequence_status;
  char *statistics_text;
  unsigned char *statistics_text_bytes;
  char statistics_path[4096];
  char raw_path[4096];
  unsigned char *raw_copy;
  int enqueue_failed = 0;

  capture_payload_bytes = malloc ((size_t) configured_capture_payload_size_bytes);
  if (capture_payload_bytes == NULL)
    {
      log_error ("Out of memory for capture payload");
      return 1; /* malloc failed */
    }
  else
    {
      if (use_initialization_sequence != 0)
        {
          if (selected_initialization_kind == PROTOCOL_INITIALIZATION_KIND_STOCK)
            {
              sequence_status = usb_send_packet_sequence (
                device_handle,
                protocol_stock_initialization_packets,
                protocol_stock_initialization_packet_count,
                capture_payload_bytes);
            }
          else
            {
              sequence_status = usb_send_packet_sequence (
                device_handle,
                protocol_windows_initialization_packets,
                protocol_windows_initialization_packet_count,
                capture_payload_bytes);
            }
        }
      else
        {
          sequence_status = usb_send_packet_sequence (
            device_handle,
            protocol_repeat_packets,
            protocol_repeat_packet_count,
            capture_payload_bytes);
        }
    }

  if (sequence_status != 0)
    {
      free (capture_payload_bytes);
      return 1; /* USB sequence failed */
    }
  else
    {
      raw_copy = malloc ((size_t) configured_capture_payload_size_bytes);
      if (raw_copy == NULL)
        {
          log_error ("Out of memory for raw payload copy");
          free (capture_payload_bytes);
          return 1; /* malloc failed */
        }
      else
        {
          memcpy (
            raw_copy,
            capture_payload_bytes,
            (size_t) configured_capture_payload_size_bytes);
          snprintf (
            raw_path,
            sizeof (raw_path),
            "%s/%s-%03d-raw.bin",
            selected_output_directory,
            selected_capture_label,
            burst_index);
          if (file_io_queue_enqueue (
                FILE_IO_JOB_KIND_WRITE_FILE,
                raw_path,
                raw_copy,
                (size_t) configured_capture_payload_size_bytes) != 0)
            {
              free (raw_copy);
              enqueue_failed = 1;
            }
          else
            {
              /* raw dump queued */
            }
        }
    }

  for (frame_index = 0; frame_index < configured_frame_count_per_capture; frame_index++)
    {
      worker_arguments[frame_index].frame_bytes =
        capture_payload_bytes + (frame_index * configured_frame_size_bytes);
      worker_arguments[frame_index].frame_statistics = &frame_statistics_list[frame_index];
      if (pthread_create (
            &statistics_threads[frame_index],
            NULL,
            frame_compute_statistics_worker,
            &worker_arguments[frame_index]) != 0)
        {
          frame_compute_statistics (
            worker_arguments[frame_index].frame_bytes,
            worker_arguments[frame_index].frame_statistics);
          statistics_thread_started[frame_index] = 0;
        }
      else
        {
          statistics_thread_started[frame_index] = 1;
        }
    }

  for (frame_index = 0; frame_index < configured_frame_count_per_capture; frame_index++)
    {
      if (statistics_thread_started[frame_index] != 0)
        {
          pthread_join (statistics_threads[frame_index], NULL);
        }
      else
        {
          /* computed on this thread already */
        }
    }

  for (frame_index = 0; frame_index < configured_frame_count_per_capture; frame_index++)
    {
      size_t pgm_size_bytes = 0;
      unsigned char *pgm_bytes;
      char pgm_path[4096];
      char frame_log_message[256];

      pgm_bytes = frame_build_pgm_bytes (
        capture_payload_bytes + (frame_index * configured_frame_size_bytes),
        &pgm_size_bytes);
      snprintf (
        pgm_path,
        sizeof (pgm_path),
        "%s/%s-%03d-frame%d.pgm",
        selected_output_directory,
        selected_capture_label,
        burst_index,
        frame_index);
      if (pgm_bytes == NULL)
        {
          log_error ("Could not build a PGM buffer");
          enqueue_failed = 1;
        }
      else
        {
          if (file_io_queue_enqueue (
                FILE_IO_JOB_KIND_WRITE_FILE,
                pgm_path,
                pgm_bytes,
                pgm_size_bytes) != 0)
            {
              free (pgm_bytes);
              enqueue_failed = 1;
            }
          else
            {
              /* PGM queued */
            }
        }

      snprintf (
        frame_log_message,
        sizeof (frame_log_message),
        "burst %d frame %d mean=%.2f stddev=%.2f min=%d max=%d all_zero=%d washed_out=%d",
        burst_index,
        frame_index,
        frame_statistics_list[frame_index].mean_value,
        frame_statistics_list[frame_index].standard_deviation,
        frame_statistics_list[frame_index].minimum_value,
        frame_statistics_list[frame_index].maximum_value,
        frame_statistics_list[frame_index].is_all_zero,
        frame_statistics_list[frame_index].is_washed_out);
      log_info (frame_log_message);
    }

  statistics_text = frame_statistics_to_text (burst_index, frame_statistics_list);
  snprintf (
    statistics_path,
    sizeof (statistics_path),
    "%s/%s-%03d-stats.txt",
    selected_output_directory,
    selected_capture_label,
    burst_index);
  if (statistics_text == NULL)
    {
      enqueue_failed = 1;
    }
  else
    {
      statistics_text_bytes = (unsigned char *) statistics_text;
      if (file_io_queue_enqueue (
            FILE_IO_JOB_KIND_WRITE_FILE,
            statistics_path,
            statistics_text_bytes,
            strlen (statistics_text)) != 0)
        {
          free (statistics_text);
          enqueue_failed = 1;
        }
      else
        {
          /* stats text queued */
        }
    }

  free (capture_payload_bytes);
  if (enqueue_failed != 0)
    {
      return 1; /* a dump job could not be queued */
    }
  else
    {
      return 0; /* burst captured and queued */
    }
}

/* =============================================================================
 * FILE I/O QUEUE
 * ============================================================================= */

/*
 * Block until every queued filesystem job has finished. The worker
 * thread performs the actual writes.
 */
static void
file_io_queue_drain (void)
{
  pthread_mutex_lock (&file_io_queue_mutex);
  while (file_io_queue_count > 0)
    {
      pthread_cond_wait (&file_io_queue_not_full, &file_io_queue_mutex);
    }
  pthread_mutex_unlock (&file_io_queue_mutex);
}

/*
 * Append one filesystem job. payload_bytes is owned by the queue after
 * a successful enqueue (the worker frees it). Returns 0 on success.
 */
static int
file_io_queue_enqueue (
  enum FileIoJobKind job_kind,
  const char *destination_path,
  unsigned char *payload_bytes,
  size_t payload_size_bytes
)
{
  pthread_mutex_lock (&file_io_queue_mutex);
  while (file_io_queue_count >= configured_file_io_queue_capacity)
    {
      pthread_cond_wait (&file_io_queue_not_full, &file_io_queue_mutex);
    }
  file_io_queue_jobs[file_io_queue_tail_index].job_kind = job_kind;
  snprintf (
    file_io_queue_jobs[file_io_queue_tail_index].destination_path,
    sizeof (file_io_queue_jobs[file_io_queue_tail_index].destination_path),
    "%s",
    destination_path);
  file_io_queue_jobs[file_io_queue_tail_index].payload_bytes = payload_bytes;
  file_io_queue_jobs[file_io_queue_tail_index].payload_size_bytes = payload_size_bytes;
  file_io_queue_tail_index =
    (file_io_queue_tail_index + 1) % configured_file_io_queue_capacity;
  file_io_queue_count += 1;
  pthread_cond_signal (&file_io_queue_not_empty);
  pthread_mutex_unlock (&file_io_queue_mutex);
  return 0; /* job is on the queue */
}

/*
 * Start the background thread that creates directories and writes files.
 */
static void
file_io_queue_start_worker (void)
{
  file_io_queue_worker_should_stop = 0;
  pthread_create (&file_io_queue_worker_thread, NULL, file_io_queue_worker, NULL);
}

/*
 * Ask the filesystem worker to exit and join it.
 */
static void
file_io_queue_stop_worker (void)
{
  pthread_mutex_lock (&file_io_queue_mutex);
  file_io_queue_worker_should_stop = 1;
  pthread_cond_signal (&file_io_queue_not_empty);
  pthread_mutex_unlock (&file_io_queue_mutex);
  pthread_join (file_io_queue_worker_thread, NULL);
}

/*
 * Drain filesystem jobs until asked to stop. mkdir -p via a small
 * recursive walk (leaf directory 0700); write-file uses open(2) at
 * mode 0600 then fwrite. unused_argument is the pthread start
 * argument (always NULL).
 */
static void *
file_io_queue_worker (void *unused_argument)
{
  (void) unused_argument;
  while (1)
    {
      struct FileIoQueueJob current_job;
      pthread_mutex_lock (&file_io_queue_mutex);
      while (file_io_queue_count == 0 && file_io_queue_worker_should_stop == 0)
        {
          pthread_cond_wait (&file_io_queue_not_empty, &file_io_queue_mutex);
        }
      if (file_io_queue_count == 0 && file_io_queue_worker_should_stop != 0)
        {
          pthread_mutex_unlock (&file_io_queue_mutex);
          return NULL; /* idle and stop requested */
        }
      else
        {
          current_job = file_io_queue_jobs[file_io_queue_head_index];
          file_io_queue_head_index =
            (file_io_queue_head_index + 1) % configured_file_io_queue_capacity;
          file_io_queue_count -= 1;
          pthread_cond_signal (&file_io_queue_not_full);
          pthread_mutex_unlock (&file_io_queue_mutex);
        }

      if (current_job.job_kind == FILE_IO_JOB_KIND_CREATE_DIRECTORY)
        {
          char path_copy[4096];
          char *slash_position;
          snprintf (path_copy, sizeof (path_copy), "%s", current_job.destination_path);
          for (slash_position = path_copy + 1; *slash_position != '\0'; slash_position++)
            {
              if (*slash_position == '/')
                {
                  *slash_position = '\0';
                  if (mkdir (path_copy, configured_capture_parent_directory_mode) != 0)
                    {
                      if (errno == EEXIST)
                        {
                          /* parent already exists */
                        }
                      else
                        {
                          file_io_queue_failed_job_count += 1;
                        }
                    }
                  else
                    {
                      /* parent created */
                    }
                  *slash_position = '/';
                }
              else
                {
                  /* not a path separator */
                }
            }
          if (mkdir (path_copy, configured_capture_directory_mode) != 0)
            {
              if (errno == EEXIST)
                {
                  if (chmod (path_copy, configured_capture_directory_mode) != 0)
                    {
                      file_io_queue_failed_job_count += 1;
                    }
                  else
                    {
                      /* existing dump directory tightened to 0700 */
                    }
                }
              else
                {
                  file_io_queue_failed_job_count += 1;
                }
            }
          else
            {
              /* destination created 0700 */
            }
        }
      else if (current_job.job_kind == FILE_IO_JOB_KIND_WRITE_FILE)
        {
          int output_file_descriptor = open (
            current_job.destination_path,
            O_CREAT | O_WRONLY | O_TRUNC,
            configured_capture_file_mode);
          if (output_file_descriptor < 0)
            {
              file_io_queue_failed_job_count += 1;
            }
          else if (fchmod (output_file_descriptor, configured_capture_file_mode) != 0)
            {
              close (output_file_descriptor);
              file_io_queue_failed_job_count += 1;
            }
          else
            {
              FILE *output_file = fdopen (output_file_descriptor, "wb");
              if (output_file == NULL)
                {
                  close (output_file_descriptor);
                  file_io_queue_failed_job_count += 1;
                }
              else
                {
                  size_t written_size = fwrite (
                    current_job.payload_bytes,
                    1,
                    current_job.payload_size_bytes,
                    output_file);
                  if (fclose (output_file) != 0)
                    {
                      file_io_queue_failed_job_count += 1;
                    }
                  else if (written_size != current_job.payload_size_bytes)
                    {
                      file_io_queue_failed_job_count += 1;
                    }
                  else
                    {
                      /* full write at mode 0600 */
                    }
                }
            }
          free (current_job.payload_bytes);
        }
      else
        {
          file_io_queue_failed_job_count += 1;
          free (current_job.payload_bytes);
        }
    }
}

/* =============================================================================
 * FRAME STATISTICS AND PGM
 * ============================================================================= */

/*
 * Build a binary PGM (P5) buffer for one 114 by 57 frame. Caller does
 * not free it after a successful enqueue. Sets pgm_size_bytes.
 */
static unsigned char *
frame_build_pgm_bytes (
  const unsigned char *frame_bytes,
  size_t *pgm_size_bytes
)
{
  char header_text[64];
  int header_length;
  unsigned char *pgm_bytes;

  header_length = snprintf (
    header_text,
    sizeof (header_text),
    "P5\n%d %d\n255\n",
    configured_frame_width_pixels,
    configured_frame_height_pixels);
  if (header_length < 0)
    {
      return NULL; /* snprintf failed */
    }
  else
    {
      *pgm_size_bytes = (size_t) header_length + (size_t) configured_frame_size_bytes;
      pgm_bytes = malloc (*pgm_size_bytes);
      if (pgm_bytes == NULL)
        {
          return NULL; /* malloc failed */
        }
      else
        {
          memcpy (pgm_bytes, header_text, (size_t) header_length);
          memcpy (
            pgm_bytes + header_length,
            frame_bytes,
            (size_t) configured_frame_size_bytes);
          return pgm_bytes; /* PGM bytes ready for the write queue */
        }
    }
}

/*
 * Fill frame_statistics from one 114 by 57 grayscale buffer.
 */
static void
frame_compute_statistics (
  const unsigned char *frame_bytes,
  struct FrameStatistics *frame_statistics
)
{
  int pixel_index;
  double sum = 0.0;
  double sum_squares = 0.0;
  int minimum_value = 255;
  int maximum_value = 0;
  int zero_pixel_count = 0;
  int saturated_pixel_count = 0;

  for (pixel_index = 0; pixel_index < configured_frame_size_bytes; pixel_index++)
    {
      int pixel_value = (int) frame_bytes[pixel_index];
      sum += (double) pixel_value;
      sum_squares += (double) pixel_value * (double) pixel_value;
      if (pixel_value < minimum_value)
        {
          minimum_value = pixel_value;
        }
      else
        {
          /* not a new minimum */
        }
      if (pixel_value > maximum_value)
        {
          maximum_value = pixel_value;
        }
      else
        {
          /* not a new maximum */
        }
      if (pixel_value == 0)
        {
          zero_pixel_count += 1;
        }
      else
        {
          /* non-zero sample */
        }
      if (pixel_value >= configured_saturated_pixel_floor)
        {
          saturated_pixel_count += 1;
        }
      else
        {
          /* not saturated */
        }
    }

  frame_statistics->mean_value = sum / (double) configured_frame_size_bytes;
  frame_statistics->standard_deviation = sqrt (
    (sum_squares / (double) configured_frame_size_bytes)
    - (frame_statistics->mean_value * frame_statistics->mean_value));
  frame_statistics->minimum_value = minimum_value;
  frame_statistics->maximum_value = maximum_value;
  frame_statistics->zero_pixel_count = zero_pixel_count;
  frame_statistics->saturated_pixel_count = saturated_pixel_count;
  if (frame_statistics->mean_value < configured_all_zero_mean_ceiling)
    {
      frame_statistics->is_all_zero = 1;
    }
  else
    {
      frame_statistics->is_all_zero = 0;
    }
  if (frame_statistics->standard_deviation < configured_washed_out_stddev_ceiling)
    {
      frame_statistics->is_washed_out = 1;
    }
  else
    {
      frame_statistics->is_washed_out = 0;
    }
}

/*
 * pthread wrapper around frame_compute_statistics.
 */
static void *
frame_compute_statistics_worker (void *worker_argument)
{
  struct FrameStatisticsWorkerArgument *typed_argument =
    (struct FrameStatisticsWorkerArgument *) worker_argument;
  frame_compute_statistics (typed_argument->frame_bytes, typed_argument->frame_statistics);
  return NULL; /* stats stored in typed_argument->frame_statistics */
}

/*
 * Heap-allocate a text report for one burst. The write queue frees it.
 */
static char *
frame_statistics_to_text (
  int burst_index,
  const struct FrameStatistics *frame_statistics_list
)
{
  char *statistics_text;
  size_t statistics_text_capacity = 4096;
  size_t statistics_text_used = 0;
  int frame_index;

  statistics_text = malloc (statistics_text_capacity);
  if (statistics_text == NULL)
    {
      return NULL; /* malloc failed */
    }
  else
    {
      int header_length = snprintf (
        statistics_text,
        statistics_text_capacity,
        "label=%s burst=%d init=%s width=%d height=%d frames=%d\n",
        selected_capture_label,
        burst_index,
        capture_initialization_kind_name (selected_initialization_kind),
        configured_frame_width_pixels,
        configured_frame_height_pixels,
        configured_frame_count_per_capture);
      if (header_length < 0)
        {
          free (statistics_text);
          return NULL; /* snprintf failed */
        }
      else
        {
          statistics_text_used = (size_t) header_length;
        }
    }

  for (frame_index = 0; frame_index < configured_frame_count_per_capture; frame_index++)
    {
      int line_length = snprintf (
        statistics_text + statistics_text_used,
        statistics_text_capacity - statistics_text_used,
        "frame=%d mean=%.4f stddev=%.4f min=%d max=%d zeros=%d saturated=%d all_zero=%d washed_out=%d\n",
        frame_index,
        frame_statistics_list[frame_index].mean_value,
        frame_statistics_list[frame_index].standard_deviation,
        frame_statistics_list[frame_index].minimum_value,
        frame_statistics_list[frame_index].maximum_value,
        frame_statistics_list[frame_index].zero_pixel_count,
        frame_statistics_list[frame_index].saturated_pixel_count,
        frame_statistics_list[frame_index].is_all_zero,
        frame_statistics_list[frame_index].is_washed_out);
      if (line_length < 0)
        {
          free (statistics_text);
          return NULL; /* snprintf failed */
        }
      else
        {
          statistics_text_used += (size_t) line_length;
        }
    }

  return statistics_text; /* heap text for the write queue */
}

/* =============================================================================
 * LOGGER
 * ============================================================================= */

/*
 * Queue an error line.
 */
static void
log_error (const char *log_message)
{
  log_queue_enqueue (LOG_SEVERITY_ERROR, log_message);
}

/*
 * Queue an informational line.
 */
static void
log_info (const char *log_message)
{
  log_queue_enqueue (LOG_SEVERITY_INFO, log_message);
}

/*
 * Block until every queued log line has been taken by the worker.
 * The worker may still be printing the last line, so callers that
 * write to stdout afterwards should wait configured_log_drain_settle_microseconds.
 */
static void
log_queue_drain (void)
{
  pthread_mutex_lock (&log_queue_mutex);
  while (log_queue_count > 0)
    {
      pthread_cond_wait (&log_queue_not_full, &log_queue_mutex);
    }
  pthread_mutex_unlock (&log_queue_mutex);
}

/*
 * Push one log line onto the logger queue.
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
 * Start the logger thread.
 */
static void
log_queue_start_worker (void)
{
  log_queue_worker_should_stop = 0;
  pthread_create (&log_queue_worker_thread, NULL, log_queue_worker, NULL);
}

/*
 * Stop the logger thread after draining.
 */
static void
log_queue_stop_worker (void)
{
  pthread_mutex_lock (&log_queue_mutex);
  log_queue_worker_should_stop = 1;
  pthread_cond_signal (&log_queue_not_empty);
  pthread_mutex_unlock (&log_queue_mutex);
  pthread_join (log_queue_worker_thread, NULL);
}

/*
 * Print queued log lines to stdout or stderr. unused_argument is the
 * pthread start argument (always NULL).
 */
static void *
log_queue_worker (void *unused_argument)
{
  (void) unused_argument;
  while (1)
    {
      struct LogQueueEntry current_entry;
      pthread_mutex_lock (&log_queue_mutex);
      while (log_queue_count == 0 && log_queue_worker_should_stop == 0)
        {
          pthread_cond_wait (&log_queue_not_empty, &log_queue_mutex);
        }
      if (log_queue_count == 0 && log_queue_worker_should_stop != 0)
        {
          pthread_mutex_unlock (&log_queue_mutex);
          return NULL; /* idle and stop requested */
        }
      else
        {
          current_entry = log_queue_entries[log_queue_head_index];
          log_queue_head_index = (log_queue_head_index + 1) % configured_log_queue_capacity;
          log_queue_count -= 1;
          pthread_cond_signal (&log_queue_not_full);
          pthread_mutex_unlock (&log_queue_mutex);
        }
      if (current_entry.log_severity == LOG_SEVERITY_ERROR)
        {
          fprintf (stderr, "sf514-egis0570-capture: %s\n", current_entry.log_message);
        }
      else
        {
          fprintf (stdout, "sf514-egis0570-capture: %s\n", current_entry.log_message);
        }
    }
}

/* =============================================================================
 * PATH / CLI
 * ============================================================================= */

/*
 * Fill selected_output_directory, selected_capture_label,
 * selected_burst_count, selected_wait_for_operator, and
 * selected_initialization_kind from argv. Returns 0 on success.
 */
static int
path_parse_command_line (
  int argument_count,
  char **argument_values
)
{
  int argument_index;

  snprintf (
    selected_output_directory,
    sizeof (selected_output_directory),
    "%s",
    configured_default_output_directory);
  snprintf (
    selected_capture_label,
    sizeof (selected_capture_label),
    "%s",
    configured_default_capture_label);
  selected_burst_count = configured_default_burst_count;
  selected_wait_for_operator = configured_default_wait_for_operator;
  selected_initialization_kind = configured_default_initialization_kind;

  for (argument_index = 1; argument_index < argument_count; argument_index++)
    {
      if (strcmp (argument_values[argument_index], "--help") == 0
          || strcmp (argument_values[argument_index], "-h") == 0)
        {
          path_print_usage (argument_values[0]);
          return 1; /* help is not a capture run */
        }
      else if (strcmp (argument_values[argument_index], "--output-dir") == 0)
        {
          if (argument_index + 1 >= argument_count)
            {
              log_error ("--output-dir needs a directory path");
              return 1; /* missing value */
            }
          else
            {
              argument_index += 1;
              snprintf (
                selected_output_directory,
                sizeof (selected_output_directory),
                "%s",
                argument_values[argument_index]);
            }
        }
      else if (strcmp (argument_values[argument_index], "--label") == 0)
        {
          if (argument_index + 1 >= argument_count)
            {
              log_error ("--label needs a name such as empty or finger");
              return 1; /* missing value */
            }
          else
            {
              argument_index += 1;
              snprintf (
                selected_capture_label,
                sizeof (selected_capture_label),
                "%s",
                argument_values[argument_index]);
            }
        }
      else if (strcmp (argument_values[argument_index], "--bursts") == 0)
        {
          if (argument_index + 1 >= argument_count)
            {
              log_error ("--bursts needs a positive integer");
              return 1; /* missing value */
            }
          else
            {
              argument_index += 1;
              selected_burst_count = atoi (argument_values[argument_index]);
              if (selected_burst_count < 1)
                {
                  log_error ("--bursts must be at least 1");
                  return 1; /* invalid value */
                }
              else
                {
                  /* burst count accepted */
                }
            }
        }
      else if (strcmp (argument_values[argument_index], "--wait") == 0)
        {
          selected_wait_for_operator = 1;
        }
      else if (strcmp (argument_values[argument_index], "--init") == 0)
        {
          if (argument_index + 1 >= argument_count)
            {
              log_error ("--init needs stock or windows");
              return 1; /* missing value */
            }
          else
            {
              argument_index += 1;
              if (strcmp (argument_values[argument_index], "stock") == 0)
                {
                  selected_initialization_kind = PROTOCOL_INITIALIZATION_KIND_STOCK;
                }
              else if (strcmp (argument_values[argument_index], "windows") == 0)
                {
                  selected_initialization_kind = PROTOCOL_INITIALIZATION_KIND_WINDOWS;
                }
              else
                {
                  log_error ("--init must be stock or windows");
                  return 1; /* unknown init name */
                }
            }
        }
      else
        {
          log_error ("Unknown argument; try --help");
          return 1; /* unknown flag */
        }
    }

  return 0; /* CLI accepted */
}

/*
 * Print CLI help to stdout.
 */
static void
path_print_usage (const char *program_name)
{
  printf (
    "Usage: %s [--output-dir DIR] [--label NAME] [--bursts N] [--wait] [--init KIND]\n"
    "Capture 114x57 frames from USB 1c7a:0570.\n"
    "  --output-dir  directory for PGM and stats (default: %s)\n"
    "  --label       name prefix such as empty or finger (default: %s)\n"
    "  --bursts      number of 5-frame captures (default: %d)\n"
    "  --wait        pause until Enter so the finger can already be on the pad\n"
    "  --init        stock (libfprint) or windows (tmullender/egis-eh570; default: windows)\n"
    "Stop fprintd first if libusb reports BUSY:\n"
    "  sudo systemctl stop fprintd.service\n",
    program_name,
    configured_default_output_directory,
    configured_default_capture_label,
    configured_default_burst_count);
}

/*
 * Drain the log queue, then wait for Enter so the operator can
 * put a finger on the pad (or leave it empty) before the first burst.
 */
static void
path_wait_for_operator_ready (void)
{
  char unused_line[256];

  log_info ("Waiting: put the pad in the capture state, then press Enter.");
  log_info (
    "Empty capture: keep the pad clear. Finger capture: hold the finger "
    "on the pad below the arrow keys before Enter.");
  log_queue_drain ();
  usleep ((useconds_t) configured_log_drain_settle_microseconds);
  fprintf (stdout, "sf514-egis0570-capture: Press Enter to capture...\n");
  fflush (stdout);
  if (fgets (unused_line, (int) sizeof (unused_line), stdin) == NULL)
    {
      log_info ("stdin closed; capturing now");
    }
  else
    {
      log_info ("Enter received; capturing now");
    }
}

/* =============================================================================
 * USB
 * ============================================================================= */

/*
 * Explain a failed libusb_open for 1c7a:0570. matching_device_count is
 * how many vid/pid matches were enumerated; libusb_status is the last
 * open error, or 0 when the pad was not on the bus.
 */
static void
usb_log_open_failure (
  int libusb_status,
  int matching_device_count
)
{
  char error_message[256];

  if (matching_device_count == 0)
    {
      log_error ("libusb did not enumerate USB 1c7a:0570 (is the pad connected?)");
    }
  else
    {
      snprintf (
        error_message,
        sizeof (error_message),
        "Found USB 1c7a:0570 but libusb_open failed: %s",
        libusb_strerror (libusb_status));
      log_error (error_message);
      if (libusb_status == LIBUSB_ERROR_ACCESS)
        {
          log_error ("The USB node is not writable for this user.");
          log_error ("Install the overlay udev rule (sudo ./scripts-fingerprint-fix/install.sh),");
          log_error ("or run this tool as root after: sudo systemctl stop fprintd.service");
        }
      else
        {
          log_error ("If fprintd holds the pad: sudo systemctl stop fprintd.service");
        }
    }
}

/*
 * Open 1c7a:0570, auto-detach a kernel driver if one is bound, and
 * claim interface 0. Returns 0 on success.
 */
static int
usb_claim_sensor (
  libusb_context **usb_context,
  libusb_device_handle **device_handle
)
{
  int libusb_status;
  char error_message[256];
  libusb_device **device_list = NULL;
  ssize_t device_count;
  ssize_t device_index;
  int matching_device_count = 0;
  int last_open_status = 0;

  *device_handle = NULL;
  libusb_status = libusb_init (usb_context);
  if (libusb_status != 0)
    {
      snprintf (
        error_message,
        sizeof (error_message),
        "libusb_init failed: %s",
        libusb_strerror (libusb_status));
      log_error (error_message);
      return 1; /* no usb context */
    }
  else
    {
      device_count = libusb_get_device_list (*usb_context, &device_list);
      if (device_count < 0)
        {
          snprintf (
            error_message,
            sizeof (error_message),
            "libusb_get_device_list failed: %s",
            libusb_strerror ((int) device_count));
          log_error (error_message);
          libusb_exit (*usb_context);
          *usb_context = NULL;
          return 1; /* cannot enumerate */
        }
      else
        {
          for (device_index = 0; device_index < device_count; device_index++)
            {
              struct libusb_device_descriptor device_descriptor;
              libusb_status = libusb_get_device_descriptor (
                device_list[device_index],
                &device_descriptor);
              if (libusb_status != 0)
                {
                  /* skip a device whose descriptor cannot be read */
                }
              else if (device_descriptor.idVendor == configured_usb_vendor_id
                       && device_descriptor.idProduct == configured_usb_product_id)
                {
                  matching_device_count += 1;
                  last_open_status = libusb_open (
                    device_list[device_index],
                    device_handle);
                  if (last_open_status == 0)
                    {
                      break; /* pad handle is in *device_handle */
                    }
                  else
                    {
                      *device_handle = NULL;
                    }
                }
              else
                {
                  /* different USB device */
                }
            }
          libusb_free_device_list (device_list, 1);
        }
    }

  if (*device_handle == NULL)
    {
      usb_log_open_failure (last_open_status, matching_device_count);
      libusb_exit (*usb_context);
      *usb_context = NULL;
      return 1; /* pad missing or not writable */
    }
  else
    {
      libusb_set_auto_detach_kernel_driver (*device_handle, 1);
      libusb_status = libusb_claim_interface (
        *device_handle,
        configured_usb_interface_number);
      if (libusb_status != 0)
        {
          snprintf (
            error_message,
            sizeof (error_message),
            "claim interface failed: %s",
            libusb_strerror (libusb_status));
          log_error (error_message);
          if (libusb_status == LIBUSB_ERROR_BUSY)
            {
              log_error ("Interface busy: sudo systemctl stop fprintd.service and retry");
            }
          else
            {
              /* other claim error */
            }
          libusb_close (*device_handle);
          libusb_exit (*usb_context);
          *device_handle = NULL;
          *usb_context = NULL;
          return 1; /* could not claim */
        }
      else
        {
          log_info ("Claimed USB interface 0 on 1c7a:0570");
          return 0; /* pad is ours */
        }
    }
}

/*
 * Release the interface and close libusb.
 */
static void
usb_close_sensor (
  libusb_context *usb_context,
  libusb_device_handle *device_handle
)
{
  if (device_handle != NULL)
    {
      libusb_release_interface (device_handle, configured_usb_interface_number);
      libusb_close (device_handle);
    }
  else
    {
      /* nothing to close */
    }
  if (usb_context != NULL)
    {
      libusb_exit (usb_context);
    }
  else
    {
      /* no context */
    }
}

/*
 * Log serial, product string, and bcdDevice, and queue a descriptor
 * text file. Returns 0 on success.
 */
static int
usb_describe_sensor (libusb_device_handle *device_handle)
{
  struct libusb_device_descriptor device_descriptor;
  unsigned char serial_text[128];
  unsigned char product_text[128];
  char description_text[512];
  char description_path[4096];
  unsigned char *description_bytes;
  int descriptor_status;
  libusb_device *usb_device;

  usb_device = libusb_get_device (device_handle);
  descriptor_status = libusb_get_device_descriptor (usb_device, &device_descriptor);
  if (descriptor_status != 0)
    {
      return 1; /* descriptor read failed */
    }
  else
    {
      serial_text[0] = '\0';
      product_text[0] = '\0';
      if (device_descriptor.iSerialNumber != 0)
        {
          libusb_get_string_descriptor_ascii (
            device_handle,
            device_descriptor.iSerialNumber,
            serial_text,
            (int) sizeof (serial_text));
        }
      else
        {
          /* no serial string */
        }
      if (device_descriptor.iProduct != 0)
        {
          libusb_get_string_descriptor_ascii (
            device_handle,
            device_descriptor.iProduct,
            product_text,
            (int) sizeof (product_text));
        }
      else
        {
          /* no product string */
        }
      snprintf (
        description_text,
        sizeof (description_text),
        "idVendor=%04x\nidProduct=%04x\nbcdDevice=%04x\nproduct=%s\nserial=%s\n",
        device_descriptor.idVendor,
        device_descriptor.idProduct,
        device_descriptor.bcdDevice,
        product_text,
        serial_text);
      log_info (description_text);
      description_bytes = malloc (strlen (description_text) + 1);
      if (description_bytes == NULL)
        {
          return 1; /* malloc failed */
        }
      else
        {
          memcpy (description_bytes, description_text, strlen (description_text) + 1);
          snprintf (
            description_path,
            sizeof (description_path),
            "%s/usb-descriptor.txt",
            selected_output_directory);
          if (file_io_queue_enqueue (
                FILE_IO_JOB_KIND_WRITE_FILE,
                description_path,
                description_bytes,
                strlen (description_text)) != 0)
            {
              free (description_bytes);
              return 1; /* enqueue failed */
            }
          else
            {
              return 0; /* descriptor recorded */
            }
        }
    }
}

/*
 * Bulk IN. Returns 0 when actual_length_bytes equals buffer_size_bytes.
 */
static int
usb_read_bulk (
  libusb_device_handle *device_handle,
  unsigned char *buffer_bytes,
  int buffer_size_bytes,
  int *actual_length_bytes
)
{
  int libusb_status;
  char error_message[256];

  libusb_status = libusb_bulk_transfer (
    device_handle,
    configured_bulk_in_endpoint,
    buffer_bytes,
    buffer_size_bytes,
    actual_length_bytes,
    configured_transfer_timeout_milliseconds);
  if (libusb_status != 0)
    {
      snprintf (
        error_message,
        sizeof (error_message),
        "bulk IN failed: %s",
        libusb_strerror (libusb_status));
      log_error (error_message);
      return 1; /* transfer error */
    }
  else if (*actual_length_bytes != buffer_size_bytes)
    {
      snprintf (
        error_message,
        sizeof (error_message),
        "bulk IN short read: got %d expected %d",
        *actual_length_bytes,
        buffer_size_bytes);
      log_error (error_message);
      return 1; /* short IN */
    }
  else
    {
      return 0; /* full IN */
    }
}

/*
 * Write a 7-byte EGIS command and read a 7-byte SIGE reply.
 */
static int
usb_send_command_expect_ack (
  libusb_device_handle *device_handle,
  const unsigned char *command_packet
)
{
  unsigned char reply_bytes[SF514_EGIS0570_COMMAND_PACKET_SIZE_BYTES];
  int actual_length_bytes = 0;

  if (usb_write_bulk (
        device_handle,
        command_packet,
        configured_command_packet_size_bytes) != 0)
    {
      return 1; /* OUT failed */
    }
  else
    {
      if (usb_read_bulk (
            device_handle,
            reply_bytes,
            configured_command_packet_size_bytes,
            &actual_length_bytes) != 0)
        {
          return 1; /* IN failed */
        }
      else
        {
          return 0; /* command ACKed */
        }
    }
}

/*
 * Write the capture command and read the 32512-byte image payload.
 */
static int
usb_send_command_expect_image (
  libusb_device_handle *device_handle,
  const unsigned char *command_packet,
  unsigned char *capture_payload_bytes
)
{
  int actual_length_bytes = 0;

  if (usb_write_bulk (
        device_handle,
        command_packet,
        configured_command_packet_size_bytes) != 0)
    {
      return 1; /* OUT failed */
    }
  else
    {
      if (usb_read_bulk (
            device_handle,
            capture_payload_bytes,
            configured_capture_payload_size_bytes,
            &actual_length_bytes) != 0)
        {
          return 1; /* image IN failed */
        }
      else
        {
          return 0; /* payload filled */
        }
    }
}

/*
 * Send every packet in the list. All but the last expect a 7-byte ACK;
 * the last packet is the capture command and fills capture_payload_bytes.
 */
static int
usb_send_packet_sequence (
  libusb_device_handle *device_handle,
  const unsigned char packets[][SF514_EGIS0570_COMMAND_PACKET_SIZE_BYTES],
  int packet_count,
  unsigned char *capture_payload_bytes
)
{
  int packet_index;

  for (packet_index = 0; packet_index < packet_count; packet_index++)
    {
      int is_last_packet;
      int packet_status;
      if (packet_index == packet_count - 1)
        {
          is_last_packet = 1;
        }
      else
        {
          is_last_packet = 0;
        }
      if (is_last_packet != 0)
        {
          packet_status = usb_send_command_expect_image (
            device_handle,
            packets[packet_index],
            capture_payload_bytes);
        }
      else
        {
          packet_status = usb_send_command_expect_ack (
            device_handle,
            packets[packet_index]);
        }
      if (packet_status != 0)
        {
          char error_message[128];
          snprintf (
            error_message,
            sizeof (error_message),
            "packet %d of %d failed",
            packet_index,
            packet_count);
          log_error (error_message);
          return 1; /* sequence aborted */
        }
      else
        {
          /* packet accepted */
        }
    }

  return 0; /* full sequence finished */
}

/*
 * Bulk OUT of buffer_size_bytes. Returns 0 on a full transfer.
 */
static int
usb_write_bulk (
  libusb_device_handle *device_handle,
  const unsigned char *buffer_bytes,
  int buffer_size_bytes
)
{
  int actual_length_bytes = 0;
  int libusb_status;
  char error_message[256];
  unsigned char *mutable_buffer;

  /* libusb 1.0 takes a non-const pointer; the bytes are not modified. */
  mutable_buffer = (unsigned char *) buffer_bytes;
  libusb_status = libusb_bulk_transfer (
    device_handle,
    configured_bulk_out_endpoint,
    mutable_buffer,
    buffer_size_bytes,
    &actual_length_bytes,
    configured_transfer_timeout_milliseconds);
  if (libusb_status != 0)
    {
      snprintf (
        error_message,
        sizeof (error_message),
        "bulk OUT failed: %s",
        libusb_strerror (libusb_status));
      log_error (error_message);
      return 1; /* transfer error */
    }
  else if (actual_length_bytes != buffer_size_bytes)
    {
      snprintf (
        error_message,
        sizeof (error_message),
        "bulk OUT short write: sent %d expected %d",
        actual_length_bytes,
        buffer_size_bytes);
      log_error (error_message);
      return 1; /* short OUT */
    }
  else
    {
      return 0; /* full OUT */
    }
}
