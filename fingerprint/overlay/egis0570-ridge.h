/*
 * Clean-room ridge matcher for EgisTec 0570 114x57 frames.
 * LGPL-2.1-or-later. No vendor coefficients.
 */

#ifndef EGIS0570_RIDGE_H
#define EGIS0570_RIDGE_H 1

#include <stdint.h>

double egis0570_ridge_frame_mean (const uint8_t *frame_bytes,
                                  int pixel_count);

double egis0570_ridge_frame_stddev (const uint8_t *frame_bytes,
                                    int pixel_count,
                                    double mean_value);

void egis0570_ridge_subtract_background (const uint8_t *frame_bytes,
                                         const uint8_t *background_bytes,
                                         uint8_t       *output_bytes,
                                         int            pixel_count);

int egis0570_ridge_finger_present (const uint8_t *frame_bytes,
                                   const uint8_t *background_bytes,
                                   int            pixel_count,
                                   double         minimum_mean,
                                   double         minimum_stddev);

double egis0570_ridge_match_score (const uint8_t *probe_bytes,
                                   const uint8_t *gallery_bytes,
                                   int            frame_width_pixels,
                                   int            frame_height_pixels);

void egis0570_ridge_pick_best_frame (const uint8_t *capture_payload,
                                     const uint8_t *background_bytes,
                                     uint8_t       *best_frame_bytes,
                                     int            frame_size_bytes,
                                     int            frame_count);

#endif
