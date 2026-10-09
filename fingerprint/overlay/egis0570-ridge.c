/*
 * Clean-room ridge matcher for EgisTec 0570 frames.
 *
 * Contrast-normalize, Gabor enhance with one global ridge
 * orientation, then normalized cross-correlation over a small
 * rotation and translation search. No vendor tables. Per-block
 * orientation on 114x57 jumped when the finger moved a few pixels.
 *
 * Copyright (C) 2026 Acer Swift SF514-52T overlay
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include "egis0570-ridge.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define EGIS0570_RIDGE_GABOR_RADIUS 5
#define EGIS0570_RIDGE_GABOR_LAMBDA 5.0
#define EGIS0570_RIDGE_GABOR_SIGMA 2.2
#define EGIS0570_RIDGE_GABOR_GAMMA 0.65
#define EGIS0570_RIDGE_TRANSLATION_RADIUS 10
#define EGIS0570_RIDGE_ROTATION_STEP_DEGREES 5.0
#define EGIS0570_RIDGE_ROTATION_LIMIT_DEGREES 10.0
#define EGIS0570_RIDGE_MIN_OVERLAP_FRACTION 0.45

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
    stddev_value = 1.0;

  for (pixel_index = 0; pixel_index < pixel_count; pixel_index++)
    {
      double value = ((double) source_bytes[pixel_index] - mean_value) / stddev_value;
      if (value < -3.0)
        value = -3.0;
      else if (value > 3.0)
        value = 3.0;
      normalized_pixels[pixel_index] = value;
    }
}

static void
egis0570_ridge_orientation_field (const double *normalized_pixels,
                                  double       *orientation_radians,
                                  int           frame_width_pixels,
                                  int           frame_height_pixels)
{
  int pixel_x;
  int pixel_y;
  double gradient_xx = 0.0;
  double gradient_yy = 0.0;
  double gradient_xy = 0.0;
  double orientation;
  int pixel_count = frame_width_pixels * frame_height_pixels;

  /*
   * One orientation for the whole 114x57 frame. Per-block fields on a
   * sensor this small jump when the finger moves a few pixels, and the
   * later NCC search cannot undo that.
   */
  for (pixel_y = 0; pixel_y < frame_height_pixels; pixel_y++)
    {
      int north = (pixel_y > 0) ? pixel_y - 1 : pixel_y;
      int south = (pixel_y + 1 < frame_height_pixels) ? pixel_y + 1 : pixel_y;
      for (pixel_x = 0; pixel_x < frame_width_pixels; pixel_x++)
        {
          int west = (pixel_x > 0) ? pixel_x - 1 : pixel_x;
          int east = (pixel_x + 1 < frame_width_pixels) ? pixel_x + 1 : pixel_x;
          double gradient_x = normalized_pixels[pixel_y * frame_width_pixels + east]
                              - normalized_pixels[pixel_y * frame_width_pixels + west];
          double gradient_y = normalized_pixels[south * frame_width_pixels + pixel_x]
                              - normalized_pixels[north * frame_width_pixels + pixel_x];
          gradient_xx += gradient_x * gradient_x;
          gradient_yy += gradient_y * gradient_y;
          gradient_xy += gradient_x * gradient_y;
        }
    }

  orientation = 0.5 * atan2 (2.0 * gradient_xy, gradient_xx - gradient_yy);
  /* Ridge orientation is perpendicular to the intensity gradient. */
  orientation += M_PI / 2.0;

  for (pixel_x = 0; pixel_x < pixel_count; pixel_x++)
    orientation_radians[pixel_x] = orientation;
}

static double
egis0570_ridge_gabor_kernel (int    offset_x,
                             int    offset_y,
                             double orientation_radians)
{
  double cosine_value = cos (orientation_radians);
  double sine_value = sin (orientation_radians);
  double rotated_x = (double) offset_x * cosine_value + (double) offset_y * sine_value;
  double rotated_y = -(double) offset_x * sine_value + (double) offset_y * cosine_value;
  double gaussian = exp (-(rotated_x * rotated_x
                           + EGIS0570_RIDGE_GABOR_GAMMA * EGIS0570_RIDGE_GABOR_GAMMA
                             * rotated_y * rotated_y)
                         / (2.0 * EGIS0570_RIDGE_GABOR_SIGMA * EGIS0570_RIDGE_GABOR_SIGMA));
  return gaussian * cos (2.0 * M_PI * rotated_x / EGIS0570_RIDGE_GABOR_LAMBDA);
}

static void
egis0570_ridge_gabor_enhance (const double *normalized_pixels,
                              const double *orientation_radians,
                              double       *enhanced_pixels,
                              int           frame_width_pixels,
                              int           frame_height_pixels)
{
  int pixel_x;
  int pixel_y;
  int kernel_x;
  int kernel_y;

  for (pixel_y = 0; pixel_y < frame_height_pixels; pixel_y++)
    {
      for (pixel_x = 0; pixel_x < frame_width_pixels; pixel_x++)
        {
          double orientation = orientation_radians[pixel_y * frame_width_pixels + pixel_x];
          double accumulator = 0.0;
          double weight_sum = 0.0;

          for (kernel_y = -EGIS0570_RIDGE_GABOR_RADIUS; kernel_y <= EGIS0570_RIDGE_GABOR_RADIUS; kernel_y++)
            {
              int sample_y = pixel_y + kernel_y;
              if (sample_y < 0 || sample_y >= frame_height_pixels)
                continue;
              for (kernel_x = -EGIS0570_RIDGE_GABOR_RADIUS; kernel_x <= EGIS0570_RIDGE_GABOR_RADIUS; kernel_x++)
                {
                  int sample_x = pixel_x + kernel_x;
                  double kernel_weight;
                  if (sample_x < 0 || sample_x >= frame_width_pixels)
                    continue;
                  kernel_weight = egis0570_ridge_gabor_kernel (kernel_x, kernel_y, orientation);
                  accumulator += kernel_weight
                                 * normalized_pixels[sample_y * frame_width_pixels + sample_x];
                  weight_sum += fabs (kernel_weight);
                }
            }

          if (weight_sum > 0.0)
            enhanced_pixels[pixel_y * frame_width_pixels + pixel_x] = accumulator / weight_sum;
          else
            enhanced_pixels[pixel_y * frame_width_pixels + pixel_x] = 0.0;
        }
    }
}

static double
egis0570_ridge_ncc_at_offset (const double *probe_pixels,
                              const double *gallery_pixels,
                              int           frame_width_pixels,
                              int           frame_height_pixels,
                              int           shift_x,
                              int           shift_y)
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
        continue;
      for (pixel_x = 0; pixel_x < frame_width_pixels; pixel_x++)
        {
          int gallery_x = pixel_x + shift_x;
          double probe_value;
          double gallery_value;
          if (gallery_x < 0 || gallery_x >= frame_width_pixels)
            continue;
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

  if (overlap_count < (double) minimum_overlap)
    return -1.0;

  numerator = overlap_count * sum_product - sum_probe * sum_gallery;
  probe_variance = overlap_count * sum_probe_squares - sum_probe * sum_probe;
  gallery_variance = overlap_count * sum_gallery_squares - sum_gallery * sum_gallery;
  if (probe_variance <= 1e-9 || gallery_variance <= 1e-9)
    return -1.0;

  denominator = sqrt (probe_variance * gallery_variance);
  if (denominator <= 1e-9)
    return -1.0;

  return numerator / denominator;
}

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
            rotated_pixels[pixel_y * frame_width_pixels + pixel_x] = 0.0;
          else
            rotated_pixels[pixel_y * frame_width_pixels + pixel_x] =
              source_pixels[nearest_y * frame_width_pixels + nearest_x];
        }
    }
}

static int
egis0570_ridge_enhance_frame (const uint8_t *frame_bytes,
                              double        *enhanced_pixels,
                              int            frame_width_pixels,
                              int            frame_height_pixels)
{
  int pixel_count = frame_width_pixels * frame_height_pixels;
  double *normalized_pixels;
  double *orientation_radians;

  normalized_pixels = calloc ((size_t) pixel_count, sizeof (double));
  orientation_radians = calloc ((size_t) pixel_count, sizeof (double));
  if (normalized_pixels == NULL || orientation_radians == NULL)
    {
      free (normalized_pixels);
      free (orientation_radians);
      return 0;
    }

  egis0570_ridge_normalize (frame_bytes, normalized_pixels, pixel_count);
  egis0570_ridge_orientation_field (normalized_pixels, orientation_radians,
                                    frame_width_pixels, frame_height_pixels);
  egis0570_ridge_gabor_enhance (normalized_pixels, orientation_radians,
                                enhanced_pixels, frame_width_pixels, frame_height_pixels);
  free (normalized_pixels);
  free (orientation_radians);
  return 1;
}

double
egis0570_ridge_match_score (const uint8_t *probe_bytes,
                            const uint8_t *gallery_bytes,
                            int            frame_width_pixels,
                            int            frame_height_pixels)
{
  int pixel_count;
  double *probe_enhanced;
  double *gallery_enhanced;
  double *rotated_probe;
  double best_score = -1.0;
  double rotation_degrees;

  if (probe_bytes == NULL || gallery_bytes == NULL
      || frame_width_pixels <= 0 || frame_height_pixels <= 0)
    return -1.0;

  pixel_count = frame_width_pixels * frame_height_pixels;
  probe_enhanced = calloc ((size_t) pixel_count, sizeof (double));
  gallery_enhanced = calloc ((size_t) pixel_count, sizeof (double));
  rotated_probe = calloc ((size_t) pixel_count, sizeof (double));
  if (probe_enhanced == NULL || gallery_enhanced == NULL || rotated_probe == NULL)
    {
      free (probe_enhanced);
      free (gallery_enhanced);
      free (rotated_probe);
      return -1.0;
    }

  if (!egis0570_ridge_enhance_frame (probe_bytes, probe_enhanced,
                                     frame_width_pixels, frame_height_pixels)
      || !egis0570_ridge_enhance_frame (gallery_bytes, gallery_enhanced,
                                        frame_width_pixels, frame_height_pixels))
    {
      free (probe_enhanced);
      free (gallery_enhanced);
      free (rotated_probe);
      return -1.0;
    }

  for (rotation_degrees = -EGIS0570_RIDGE_ROTATION_LIMIT_DEGREES;
       rotation_degrees <= EGIS0570_RIDGE_ROTATION_LIMIT_DEGREES + 0.01;
       rotation_degrees += EGIS0570_RIDGE_ROTATION_STEP_DEGREES)
    {
      int shift_x;
      int shift_y;
      double angle_radians = rotation_degrees * M_PI / 180.0;
      egis0570_ridge_rotate_nearest (probe_enhanced, rotated_probe,
                                     frame_width_pixels, frame_height_pixels,
                                     angle_radians);
      for (shift_y = -EGIS0570_RIDGE_TRANSLATION_RADIUS; shift_y <= EGIS0570_RIDGE_TRANSLATION_RADIUS; shift_y++)
        {
          for (shift_x = -EGIS0570_RIDGE_TRANSLATION_RADIUS; shift_x <= EGIS0570_RIDGE_TRANSLATION_RADIUS; shift_x++)
            {
              double score = egis0570_ridge_ncc_at_offset (rotated_probe,
                                                           gallery_enhanced,
                                                           frame_width_pixels,
                                                           frame_height_pixels,
                                                           shift_x,
                                                           shift_y);
              if (score > best_score)
                best_score = score;
            }
        }
    }

  free (probe_enhanced);
  free (gallery_enhanced);
  free (rotated_probe);
  return best_score;
}
