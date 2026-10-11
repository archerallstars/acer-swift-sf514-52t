/*
 * Clean-room ridge matcher for EgisTec 0570 frames.
 *
 * Contrast-normalize each 114x57 frame (z-score, clamp ±3), then
 * normalized cross-correlation over rotation (±15°) and translation
 * (±20 px). Live re-press on this pad passed at 0.65 / 0.49 with
 * that formula. A bright-pixel mask (threshold 12) then dropped
 * full-coverage re-presses (probe_skin 0.99–1.00, mean ~50) to
 * ~0.36: ridge valleys sit near that threshold, and raw Pearson
 * is more pressure-sensitive than clamped z-score. Same-hold
 * capture dumps still score ~0.90; they are not a re-press test.
 *
 * Copyright (C) 2026 Acer Swift SF514-52T overlay
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include "egis0570-ridge.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define EGIS0570_RIDGE_TRANSLATION_RADIUS 20
#define EGIS0570_RIDGE_ROTATION_STEP_DEGREES 5.0
#define EGIS0570_RIDGE_ROTATION_LIMIT_DEGREES 15.0
/* Geometric overlap must cover at least this fraction of the 114x57 pad. */
#define EGIS0570_RIDGE_MIN_OVERLAP_FRACTION 0.45
/* Journal-only: subtracted pixel at or above this value counts as signal. */
#define EGIS0570_RIDGE_SIGNAL_THRESHOLD 12

double
egis0570_ridge_frame_mean (const uint8_t *frame_bytes,
                           int            pixel_count)
{
  double sum = 0.0;
  int pixel_index;

  if (frame_bytes == NULL || pixel_count <= 0)
    return 0.0;

  for (pixel_index = 0; pixel_index < pixel_count; pixel_index++)
    sum += (double) frame_bytes[pixel_index];

  return sum / (double) pixel_count;
}

double
egis0570_ridge_frame_stddev (const uint8_t *frame_bytes,
                             int            pixel_count,
                             double         mean_value)
{
  double sum_squares = 0.0;
  int pixel_index;

  if (frame_bytes == NULL || pixel_count <= 0)
    return 0.0;

  for (pixel_index = 0; pixel_index < pixel_count; pixel_index++)
    {
      double delta = (double) frame_bytes[pixel_index] - mean_value;
      sum_squares += delta * delta;
    }

  return sqrt (sum_squares / (double) pixel_count);
}

void
egis0570_ridge_subtract_background (const uint8_t *frame_bytes,
                                    const uint8_t *background_bytes,
                                    uint8_t       *output_bytes,
                                    int            pixel_count)
{
  int pixel_index;

  if (frame_bytes == NULL || output_bytes == NULL || pixel_count <= 0)
    return;

  if (background_bytes == NULL)
    {
      memcpy (output_bytes, frame_bytes, (size_t) pixel_count);
      return;
    }

  for (pixel_index = 0; pixel_index < pixel_count; pixel_index++)
    {
      int subtracted = (int) frame_bytes[pixel_index] - (int) background_bytes[pixel_index];
      if (subtracted < 0)
        output_bytes[pixel_index] = 0;
      else if (subtracted > 255)
        output_bytes[pixel_index] = 255;
      else
        output_bytes[pixel_index] = (uint8_t) subtracted;
    }
}

int
egis0570_ridge_finger_present (const uint8_t *frame_bytes,
                               const uint8_t *background_bytes,
                               int            pixel_count,
                               double         minimum_mean,
                               double         minimum_stddev)
{
  uint8_t *subtracted;
  double mean_value;
  double stddev_value;
  int present;

  if (frame_bytes == NULL || pixel_count <= 0)
    return 0;

  subtracted = malloc ((size_t) pixel_count);
  if (subtracted == NULL)
    return 0;

  egis0570_ridge_subtract_background (frame_bytes, background_bytes,
                                      subtracted, pixel_count);
  mean_value = egis0570_ridge_frame_mean (subtracted, pixel_count);
  stddev_value = egis0570_ridge_frame_stddev (subtracted, pixel_count, mean_value);
  present = (mean_value >= minimum_mean && stddev_value >= minimum_stddev) ? 1 : 0;
  free (subtracted);
  return present;
}

void
egis0570_ridge_pick_best_frame (const uint8_t *capture_payload,
                                const uint8_t *background_bytes,
                                uint8_t       *best_frame_bytes,
                                int            frame_size_bytes,
                                int            frame_count)
{
  int frame_index;
  int best_index = 0;
  double best_stddev = -1.0;
  uint8_t *subtracted;

  if (capture_payload == NULL || best_frame_bytes == NULL ||
      frame_size_bytes <= 0 || frame_count <= 0)
    return;

  subtracted = malloc ((size_t) frame_size_bytes);
  if (subtracted == NULL)
    {
      memcpy (best_frame_bytes, capture_payload, (size_t) frame_size_bytes);
      return;
    }

  for (frame_index = 0; frame_index < frame_count; frame_index++)
    {
      const uint8_t *frame_bytes = capture_payload + (frame_index * frame_size_bytes);
      double mean_value;
      double stddev_value;

      egis0570_ridge_subtract_background (frame_bytes, background_bytes,
                                          subtracted, frame_size_bytes);
      mean_value = egis0570_ridge_frame_mean (subtracted, frame_size_bytes);
      stddev_value = egis0570_ridge_frame_stddev (subtracted, frame_size_bytes, mean_value);
      if (stddev_value > best_stddev)
        {
          best_stddev = stddev_value;
          best_index = frame_index;
        }
    }

  memcpy (best_frame_bytes,
          capture_payload + (best_index * frame_size_bytes),
          (size_t) frame_size_bytes);
  free (subtracted);
}

/*
 * Count pixels at or above the skin threshold. Returns 0 when the
 * frame is missing or empty.
 */
static int
egis0570_ridge_count_signal_pixels (const uint8_t *frame_bytes,
                                    int            pixel_count)
{
  int pixel_index;
  int signal_pixel_count = 0;

  if (frame_bytes == NULL || pixel_count <= 0)
    {
      return 0; /* no frame to inspect */
    }
  else
    {
      for (pixel_index = 0; pixel_index < pixel_count; pixel_index++)
        {
          if (frame_bytes[pixel_index] >= EGIS0570_RIDGE_SIGNAL_THRESHOLD)
            {
              signal_pixel_count += 1;
            }
          else
            {
              /* empty-pad residual after subtract */
            }
        }
      return signal_pixel_count; /* skin pixel count */
    }
}

/*
 * Return the fraction of pixels that look like finger after background
 * subtract (0..1). Verify journal lines use this so a light or
 * off-centre press is visible next to the match score.
 */
double
egis0570_ridge_signal_fraction (const uint8_t *frame_bytes,
                                int            pixel_count)
{
  if (frame_bytes == NULL || pixel_count <= 0)
    {
      return 0.0; /* no frame to inspect */
    }
  else
    {
      return (double) egis0570_ridge_count_signal_pixels (frame_bytes, pixel_count)
             / (double) pixel_count; /* skin coverage */
    }
}

/*
 * Z-score source_bytes into normalized_pixels. Stddev is floored at
 * 1.0 so a flat frame does not explode. Values are clamped to ±3 so
 * a harder press does not dominate the correlation.
 */
static void
egis0570_ridge_normalize (const uint8_t *source_bytes,
                          double        *normalized_pixels,
                          int            pixel_count)
{
  double mean_value;
  double stddev_value;
  int pixel_index;

  mean_value = egis0570_ridge_frame_mean (source_bytes, pixel_count);
  stddev_value = egis0570_ridge_frame_stddev (source_bytes, pixel_count, mean_value);
  if (stddev_value < 1.0)
    {
      stddev_value = 1.0;
    }
  else
    {
      /* measured contrast is already usable */
    }

  for (pixel_index = 0; pixel_index < pixel_count; pixel_index++)
    {
      double value = ((double) source_bytes[pixel_index] - mean_value) / stddev_value;
      if (value < -3.0)
        {
          value = -3.0;
        }
      else if (value > 3.0)
        {
          value = 3.0;
        }
      else
        {
          /* already in range */
        }
      normalized_pixels[pixel_index] = value;
    }
}

/*
 * Pearson correlation of z-scored pixels with gallery shifted by
 * shift_x / shift_y. Every overlapping pixel is used, including
 * ridge valleys. Returns -1 when the overlap is too small.
 */
static double
egis0570_ridge_ncc_at_offset (
  const double *probe_pixels,
  const double *gallery_pixels,
  int           frame_width_pixels,
  int           frame_height_pixels,
  int           shift_x,
  int           shift_y
)
{
  int pixel_x;
  int pixel_y;
  double sum_probe = 0.0;
  double sum_gallery = 0.0;
  double sum_probe_squares = 0.0;
  double sum_gallery_squares = 0.0;
  double sum_product = 0.0;
  double overlap_count = 0.0;
  double numerator;
  double probe_variance;
  double gallery_variance;
  double denominator;
  int minimum_overlap;

  minimum_overlap = (int) (EGIS0570_RIDGE_MIN_OVERLAP_FRACTION
                           * (double) frame_width_pixels
                           * (double) frame_height_pixels);

  for (pixel_y = 0; pixel_y < frame_height_pixels; pixel_y++)
    {
      int gallery_y = pixel_y + shift_y;
      if (gallery_y < 0 || gallery_y >= frame_height_pixels)
        {
          continue; /* this probe row falls off the gallery */
        }
      else
        {
          for (pixel_x = 0; pixel_x < frame_width_pixels; pixel_x++)
            {
              int gallery_x = pixel_x + shift_x;
              double probe_value;
              double gallery_value;
              if (gallery_x < 0 || gallery_x >= frame_width_pixels)
                {
                  continue; /* this probe column falls off the gallery */
                }
              else
                {
                  probe_value = probe_pixels[pixel_y * frame_width_pixels + pixel_x];
                  gallery_value = gallery_pixels[gallery_y * frame_width_pixels + gallery_x];
                  sum_probe += probe_value;
                  sum_gallery += gallery_value;
                  sum_probe_squares += probe_value * probe_value;
                  sum_gallery_squares += gallery_value * gallery_value;
                  sum_product += probe_value * gallery_value;
                  overlap_count += 1.0;
                }
            }
        }
    }

  if (overlap_count < (double) minimum_overlap)
    {
      return -1.0; /* not enough overlapping pixels to score */
    }
  else
    {
      numerator = overlap_count * sum_product - sum_probe * sum_gallery;
      probe_variance = overlap_count * sum_probe_squares - sum_probe * sum_probe;
      gallery_variance = overlap_count * sum_gallery_squares - sum_gallery * sum_gallery;
      if (probe_variance <= 1e-9 || gallery_variance <= 1e-9)
        {
          return -1.0; /* a side is constant, so correlation is undefined */
        }
      else
        {
          denominator = sqrt (probe_variance * gallery_variance);
          if (denominator <= 1e-9)
            {
              return -1.0; /* degenerate correlation */
            }
          else
            {
              return numerator / denominator; /* Pearson on the overlapping window */
            }
        }
    }
}

/*
 * Rotate source_pixels around the frame centre into rotated_pixels
 * using nearest-neighbour sampling. Pixels that fall outside the
 * frame are written as 0.0 (the z-score mean).
 */
static void
egis0570_ridge_rotate_nearest (const double *source_pixels,
                               double       *rotated_pixels,
                               int           frame_width_pixels,
                               int           frame_height_pixels,
                               double        angle_radians)
{
  int pixel_x;
  int pixel_y;
  double cosine_value = cos (angle_radians);
  double sine_value = sin (angle_radians);
  double center_x = ((double) frame_width_pixels - 1.0) / 2.0;
  double center_y = ((double) frame_height_pixels - 1.0) / 2.0;

  for (pixel_y = 0; pixel_y < frame_height_pixels; pixel_y++)
    {
      for (pixel_x = 0; pixel_x < frame_width_pixels; pixel_x++)
        {
          double relative_x = (double) pixel_x - center_x;
          double relative_y = (double) pixel_y - center_y;
          double source_x = cosine_value * relative_x + sine_value * relative_y + center_x;
          double source_y = -sine_value * relative_x + cosine_value * relative_y + center_y;
          int nearest_x = (int) floor (source_x + 0.5);
          int nearest_y = (int) floor (source_y + 0.5);
          if (nearest_x < 0 || nearest_x >= frame_width_pixels
              || nearest_y < 0 || nearest_y >= frame_height_pixels)
            {
              rotated_pixels[pixel_y * frame_width_pixels + pixel_x] = 0.0;
            }
          else
            {
              rotated_pixels[pixel_y * frame_width_pixels + pixel_x] =
                source_pixels[nearest_y * frame_width_pixels + nearest_x];
            }
        }
    }
}

/*
 * Score probe_bytes against gallery_bytes. Both must be 114x57
 * background-subtracted frames. Returns the highest z-score NCC
 * over the rotation and translation search, or -1 when the frames
 * cannot be scored.
 */
double
egis0570_ridge_match_score (const uint8_t *probe_bytes,
                            const uint8_t *gallery_bytes,
                            int            frame_width_pixels,
                            int            frame_height_pixels)
{
  int pixel_count;
  double *probe_normalized;
  double *gallery_normalized;
  double *rotated_probe;
  double best_score = -1.0;
  double rotation_degrees;

  if (probe_bytes == NULL || gallery_bytes == NULL
      || frame_width_pixels <= 0 || frame_height_pixels <= 0)
    {
      return -1.0; /* missing frames or empty geometry */
    }
  else
    {
      pixel_count = frame_width_pixels * frame_height_pixels;
      probe_normalized = calloc ((size_t) pixel_count, sizeof (double));
      gallery_normalized = calloc ((size_t) pixel_count, sizeof (double));
      rotated_probe = calloc ((size_t) pixel_count, sizeof (double));
      if (probe_normalized == NULL || gallery_normalized == NULL
          || rotated_probe == NULL)
        {
          free (probe_normalized);
          free (gallery_normalized);
          free (rotated_probe);
          return -1.0; /* allocation failed */
        }
      else
        {
          egis0570_ridge_normalize (probe_bytes, probe_normalized, pixel_count);
          egis0570_ridge_normalize (gallery_bytes, gallery_normalized, pixel_count);
          for (rotation_degrees = -EGIS0570_RIDGE_ROTATION_LIMIT_DEGREES;
               rotation_degrees <= EGIS0570_RIDGE_ROTATION_LIMIT_DEGREES + 0.01;
               rotation_degrees += EGIS0570_RIDGE_ROTATION_STEP_DEGREES)
            {
              int shift_x;
              int shift_y;
              double angle_radians = rotation_degrees * M_PI / 180.0;
              egis0570_ridge_rotate_nearest (probe_normalized, rotated_probe,
                                             frame_width_pixels, frame_height_pixels,
                                             angle_radians);
              for (shift_y = -EGIS0570_RIDGE_TRANSLATION_RADIUS;
                   shift_y <= EGIS0570_RIDGE_TRANSLATION_RADIUS;
                   shift_y++)
                {
                  for (shift_x = -EGIS0570_RIDGE_TRANSLATION_RADIUS;
                       shift_x <= EGIS0570_RIDGE_TRANSLATION_RADIUS;
                       shift_x++)
                    {
                      double score = egis0570_ridge_ncc_at_offset (
                        rotated_probe,
                        gallery_normalized,
                        frame_width_pixels,
                        frame_height_pixels,
                        shift_x,
                        shift_y);
                      if (score > best_score)
                        {
                          best_score = score;
                        }
                      else
                        {
                          /* this alignment scored lower */
                        }
                    }
                }
            }
          free (probe_normalized);
          free (gallery_normalized);
          free (rotated_probe);
          return best_score; /* highest z-score NCC over rotation and translation */
        }
    }
}
