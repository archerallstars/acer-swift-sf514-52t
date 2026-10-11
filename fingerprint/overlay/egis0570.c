/*
 * Egis Technology Inc. (aka. LighTuning) 0570 driver for libfprint
 *
 * Press-mode overlay for USB 1c7a:0570 / 1c7a:0571. Host-side matching
 * stores 114x57 frames as FPI_PRINT_RAW and scores them with the
 * clean-room contrast-normalize plus NCC matcher in egis0570-ridge.c.
 *
 * Copyright (C) 2021 Maxim Kolesnikov <kolesnikov@svyazcom.ru>
 * Copyright (C) 2021 Saeed/Ali Rk <saeed.ali.rahimi@gmail.com>
 * Copyright (C) 2026 Acer Swift SF514-52T overlay
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 */

#define FP_COMPONENT "egis0570"

#include "egis0570.h"
#include "egis0570-ridge.h"
#include "drivers_api.h"

#include <string.h>

enum {
  EGIS0570_PKT_INIT,
  EGIS0570_PKT_REPEAT,
};

enum {
  EGIS0570_PHASE_BACKGROUND,
  EGIS0570_PHASE_WAIT_FINGER,
  EGIS0570_PHASE_HOLD_FINGER,
  EGIS0570_PHASE_WAIT_LIFT,
};

enum sm_states {
  SM_START,
  SM_REQ,
  SM_RESP,
  SM_REC_DATA,
  SM_PAUSE,
  SM_STATES_NUM
};

/*
 * Where a new enroll press sits relative to strips already stored.
 * FIRST has no gallery yet. NEIGHBOUR is the sweet band. TOO_SIMILAR
 * and TOO_FAR are retried so the three stages form a continuous band.
 */
enum Egis0570EnrollStripSpacing
{
  EGIS0570_ENROLL_STRIP_SPACING_FIRST = 0,
  EGIS0570_ENROLL_STRIP_SPACING_NEIGHBOUR,
  EGIS0570_ENROLL_STRIP_SPACING_TOO_SIMILAR,
  EGIS0570_ENROLL_STRIP_SPACING_TOO_FAR,
};

struct _FpDeviceEgis0570
{
  FpDevice parent;

  FpiSsm  *ssm;
  gboolean running;
  gboolean cancelling;
  gboolean action_reported;

  int      pkt_num;
  int      pkt_type;
  int      phase;
  int      hold_bursts;
  int      enroll_stage;

  guint8  *background;
  guint8  *hold_frames[EGIS0570_HOLD_BURSTS];
  int      hold_frame_count;
};

G_DECLARE_FINAL_TYPE (FpDeviceEgis0570, fpi_device_egis0570, FPI, DEVICE_EGIS0570, FpDevice);
G_DEFINE_TYPE (FpDeviceEgis0570, fpi_device_egis0570, FP_TYPE_DEVICE);

static void loop_complete (FpiSsm *ssm, FpDevice *dev, GError *error);
static void ssm_run_state (FpiSsm *ssm, FpDevice *dev);
static void start_capture_loop (FpDevice *dev);
static double best_score_against_template (const guint8 *probe_bytes,
                                           GVariant     *gallery);
static enum Egis0570EnrollStripSpacing enroll_classify_strip_spacing (
  FpDeviceEgis0570 *self,
  GVariant         *existing_gallery,
  double           *highest_similarity);

static gboolean
is_last_pkt (FpDevice *dev)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);

  if (self->pkt_type == EGIS0570_PKT_INIT)
    return self->pkt_num == (int) EGIS0570_INIT_TOTAL - 1;

  return self->pkt_num == (int) EGIS0570_REPEAT_TOTAL - 1;
}

static void
update_background_from_payload (FpDeviceEgis0570 *self,
                                const guint8     *payload)
{
  int frame_index;
  int pixel_index;

  if (!self->background)
    self->background = g_malloc (EGIS0570_IMGSIZE);

  memset (self->background, 255, EGIS0570_IMGSIZE);

  for (frame_index = 0; frame_index < EGIS0570_IMGCOUNT; frame_index++)
    {
      const guint8 *frame = payload + (frame_index * EGIS0570_IMGSIZE);
      for (pixel_index = 0; pixel_index < EGIS0570_IMGSIZE; pixel_index++)
        {
          if (frame[pixel_index] < self->background[pixel_index])
            self->background[pixel_index] = frame[pixel_index];
        }
    }
}

static gboolean
payload_has_finger (FpDeviceEgis0570 *self,
                    const guint8     *payload)
{
  int frame_index;

  for (frame_index = 0; frame_index < EGIS0570_IMGCOUNT; frame_index++)
    {
      const guint8 *frame = payload + (frame_index * EGIS0570_IMGSIZE);
      if (egis0570_ridge_finger_present (frame,
                                         self->background,
                                         EGIS0570_IMGSIZE,
                                         EGIS0570_MIN_MEAN,
                                         EGIS0570_MIN_STDDEV))
        return TRUE;
    }

  return FALSE;
}

/* Free every stored hold burst and reset the count. */
static void
clear_hold_frames (FpDeviceEgis0570 *self)
{
  int hold_index;

  for (hold_index = 0; hold_index < EGIS0570_HOLD_BURSTS; hold_index++)
    g_clear_pointer (&self->hold_frames[hold_index], g_free);
  self->hold_frame_count = 0;
}

/*
 * Keep the highest-contrast frame of this 5-frame burst as the next
 * hold slot. Verify scores every stored burst. Enroll stores every
 * burst so one press contributes several micro-shifts of that
 * fingertip strip.
 */
static void
remember_hold_burst_frame (FpDeviceEgis0570 *self,
                           const guint8     *payload)
{
  guint8 candidate[EGIS0570_IMGSIZE];
  int slot_index;

  if (self->hold_frame_count >= EGIS0570_HOLD_BURSTS)
    {
      return; /* already have a full hold */
    }
  else
    {
      slot_index = self->hold_frame_count;
      egis0570_ridge_pick_best_frame (payload,
                                      self->background,
                                      candidate,
                                      EGIS0570_IMGSIZE,
                                      EGIS0570_IMGCOUNT);
      if (!self->hold_frames[slot_index])
        self->hold_frames[slot_index] = g_malloc (EGIS0570_IMGSIZE);
      memcpy (self->hold_frames[slot_index], candidate, EGIS0570_IMGSIZE);
      self->hold_frame_count += 1;
    }
}

/*
 * Place this hold against already stored enroll strips.
 *
 * existing_gallery is the print's fpi-data (NULL on the first
 * section). highest_similarity receives the best z-score NCC of
 * the hold bursts against that gallery, or -1.0 when there is
 * nothing to score. First section is always FIRST. A later
 * section must sit in the sweet band: below TOO_SIMILAR and
 * above TOO_FAR. A score below 0 (unusable gallery) does not
 * block enroll.
 */
static enum Egis0570EnrollStripSpacing
enroll_classify_strip_spacing (
  FpDeviceEgis0570 *self,
  GVariant         *existing_gallery,
  double           *highest_similarity
)
{
  int hold_index;
  double best_similarity = -1.0;
  guint8 subtracted[EGIS0570_IMGSIZE];

  if (existing_gallery == NULL)
    {
      if (highest_similarity != NULL)
        {
          *highest_similarity = -1.0;
        }
      else
        {
          /* caller does not need the score */
        }
      return EGIS0570_ENROLL_STRIP_SPACING_FIRST; /* no stored strips yet */
    }
  else
    {
      for (hold_index = 0; hold_index < self->hold_frame_count; hold_index++)
        {
          double score;

          egis0570_ridge_subtract_background (self->hold_frames[hold_index],
                                              self->background,
                                              subtracted,
                                              EGIS0570_IMGSIZE);
          score = best_score_against_template (subtracted, existing_gallery);
          if (score > best_similarity)
            {
              best_similarity = score;
            }
          else
            {
              /* this burst matches stored strips less */
            }
        }
      if (highest_similarity != NULL)
        {
          *highest_similarity = best_similarity;
        }
      else
        {
          /* caller does not need the score */
        }
      if (best_similarity < 0.0)
        {
          return EGIS0570_ENROLL_STRIP_SPACING_NEIGHBOUR; /* unusable score, do not block */
        }
      else if (best_similarity >= EGIS0570_ENROLL_TOO_SIMILAR)
        {
          return EGIS0570_ENROLL_STRIP_SPACING_TOO_SIMILAR; /* same height as a stored strip */
        }
      else if (best_similarity <= EGIS0570_ENROLL_TOO_FAR)
        {
          return EGIS0570_ENROLL_STRIP_SPACING_TOO_FAR; /* jumped a gap along the finger */
        }
      else
        {
          return EGIS0570_ENROLL_STRIP_SPACING_NEIGHBOUR; /* sweet band, photograph this skin */
        }
    }
}

static GVariant *
append_frame_to_print_data (GVariant      *existing,
                            const guint8  *frame_bytes)
{
  GVariantBuilder builder;
  GVariant *frame_variant;
  guint8 *owned_frame_bytes;

  g_variant_builder_init (&builder, G_VARIANT_TYPE ("aay"));
  if (existing)
    {
      gsize child_index;
      for (child_index = 0; child_index < g_variant_n_children (existing); child_index++)
        {
          GVariant *existing_child = g_variant_get_child_value (existing, child_index);
          g_variant_builder_add_value (&builder, existing_child);
          g_variant_unref (existing_child);
        }
    }
  else
    {
      /* First enroll stage: the print has no gallery frames yet. */
    }

  owned_frame_bytes = g_memdup2 (frame_bytes, EGIS0570_IMGSIZE);
  frame_variant = g_variant_new_from_data (G_VARIANT_TYPE ("ay"),
                                           owned_frame_bytes,
                                           EGIS0570_IMGSIZE,
                                           TRUE,
                                           g_free,
                                           owned_frame_bytes);
  g_variant_builder_add_value (&builder, frame_variant);
  return g_variant_builder_end (&builder);
}

static double
best_score_against_template (const guint8 *probe_bytes,
                             GVariant     *gallery)
{
  gsize child_index;
  double best_score = -1.0;

  if (!gallery)
    {
      return best_score; /* no stored frames */
    }
  else if (g_variant_is_of_type (gallery, G_VARIANT_TYPE ("ay")))
    {
      gsize length = 0;
      const guint8 *gallery_bytes = g_variant_get_fixed_array (gallery, &length, 1);

      if (gallery_bytes && length == EGIS0570_IMGSIZE)
        {
          return egis0570_ridge_match_score (probe_bytes,
                                             gallery_bytes,
                                             EGIS0570_IMGWIDTH,
                                             EGIS0570_IMGHEIGHT);
        }
      else
        {
          return best_score; /* unexpected single-frame size */
        }
    }
  else if (!g_variant_is_of_type (gallery, G_VARIANT_TYPE ("aay")))
    {
      fp_warn ("gallery type %s is not aay", g_variant_get_type_string (gallery));
      return best_score; /* unusable gallery */
    }
  else
    {
      for (child_index = 0; child_index < g_variant_n_children (gallery); child_index++)
        {
          g_autoptr(GVariant) child = g_variant_get_child_value (gallery, child_index);
          gsize length = 0;
          const guint8 *gallery_bytes;
          double score;

          gallery_bytes = g_variant_get_fixed_array (child, &length, 1);
          if (!gallery_bytes || length != EGIS0570_IMGSIZE)
            {
              continue; /* skip a truncated or non-byte child */
            }
          else
            {
              score = egis0570_ridge_match_score (probe_bytes,
                                                  gallery_bytes,
                                                  EGIS0570_IMGWIDTH,
                                                  EGIS0570_IMGHEIGHT);
              if (score > best_score)
                {
                  best_score = score;
                }
              else
                {
                  /* this gallery frame scored lower */
                }
            }
        }

      return best_score; /* highest z-score NCC across enrolled frames */
    }
}

static void
log_match_attempt (const char    *action_name,
                   double         score,
                   GVariant      *gallery,
                   const guint8  *probe_bytes,
                   int            hold_frame_count)
{
  double probe_mean;
  double probe_stddev;
  double probe_skin;
  const gchar *gallery_type = "none";
  gsize gallery_frames = 0;

  probe_mean = egis0570_ridge_frame_mean (probe_bytes, EGIS0570_IMGSIZE);
  probe_stddev = egis0570_ridge_frame_stddev (probe_bytes, EGIS0570_IMGSIZE, probe_mean);
  probe_skin = egis0570_ridge_signal_fraction (probe_bytes, EGIS0570_IMGSIZE);
  if (gallery)
    {
      gallery_type = g_variant_get_type_string (gallery);
      gallery_frames = g_variant_n_children (gallery);
    }
  else
    {
      gallery_type = "none";
      gallery_frames = 0;
    }

  g_message ("%s score=%.4f threshold=%.2f gallery_type=%s gallery_frames=%lu probe_mean=%.2f probe_stddev=%.2f probe_skin=%.2f hold_frames=%d",
             action_name,
             score,
             EGIS0570_MATCH_THRESHOLD,
             gallery_type,
             (unsigned long) gallery_frames,
             probe_mean,
             probe_stddev,
             probe_skin,
             hold_frame_count);
}

static void
finish_action_error (FpDevice *dev, GError *error)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);
  FpiDeviceAction action = fpi_device_get_current_action (dev);

  if (self->action_reported)
    {
      g_clear_error (&error);
      return;
    }

  self->action_reported = TRUE;

  switch (action)
    {
    case FPI_DEVICE_ACTION_ENROLL:
      fpi_device_enroll_complete (dev, NULL, error);
      break;
    case FPI_DEVICE_ACTION_VERIFY:
      fpi_device_verify_complete (dev, error);
      break;
    case FPI_DEVICE_ACTION_IDENTIFY:
      fpi_device_identify_complete (dev, error);
      break;
    case FPI_DEVICE_ACTION_NONE:
    case FPI_DEVICE_ACTION_PROBE:
    case FPI_DEVICE_ACTION_OPEN:
    case FPI_DEVICE_ACTION_CLOSE:
    case FPI_DEVICE_ACTION_CAPTURE:
    case FPI_DEVICE_ACTION_LIST:
    case FPI_DEVICE_ACTION_DELETE:
    case FPI_DEVICE_ACTION_CLEAR_STORAGE:
    default:
      fpi_device_action_error (dev, error);
      break;
    }
}

static void
complete_verify_or_identify (FpDevice *dev, FpiMatchResult match_result, FpPrint *matched)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);
  FpiDeviceAction action = fpi_device_get_current_action (dev);

  if (self->action_reported)
    return;

  self->action_reported = TRUE;

  if (action == FPI_DEVICE_ACTION_VERIFY)
    {
      fpi_device_verify_report (dev, match_result, NULL, NULL);
      fpi_device_verify_complete (dev, NULL);
    }
  else if (action == FPI_DEVICE_ACTION_IDENTIFY)
    {
      fpi_device_identify_report (dev, matched, NULL, NULL);
      fpi_device_identify_complete (dev, NULL);
    }
}

static void
accept_held_frame (FpDevice *dev)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);
  FpiDeviceAction action = fpi_device_get_current_action (dev);
  guint8 subtracted[EGIS0570_IMGSIZE];

  if (self->hold_frame_count <= 0)
    {
      if (action == FPI_DEVICE_ACTION_ENROLL)
        {
          fpi_device_enroll_progress (dev, self->enroll_stage, NULL,
                                      fpi_device_retry_new (FP_DEVICE_RETRY_GENERAL));
        }
      else if (action == FPI_DEVICE_ACTION_VERIFY ||
               action == FPI_DEVICE_ACTION_IDENTIFY)
        {
          complete_verify_or_identify (dev, FPI_MATCH_FAIL, NULL);
          self->cancelling = TRUE;
        }
      else
        {
          /* Open/close/cancel do not consume a held frame. */
        }
      return;
    }

  if (action == FPI_DEVICE_ACTION_ENROLL)
    {
      FpPrint *print = NULL;
      g_autoptr(GVariant) existing = NULL;
      GVariant *updated = NULL;
      double highest_similarity = -1.0;
      int hold_index;
      enum Egis0570EnrollStripSpacing strip_spacing;

      fpi_device_get_enroll_data (dev, &print);
      if (self->enroll_stage == 0)
        {
          fpi_print_set_type (print, FPI_PRINT_RAW);
        }
      else
        {
          /* later sections keep the RAW type set on the first */
        }
      g_object_get (print, "fpi-data", &existing, NULL);

      strip_spacing = enroll_classify_strip_spacing (self, existing,
                                                     &highest_similarity);
      if (strip_spacing == EGIS0570_ENROLL_STRIP_SPACING_TOO_SIMILAR)
        {
          g_message ("enroll section=%d similarity=%.4f too_similar_at=%.2f too_far_at=%.2f hold_frames=%d (slide toward nail or joint)",
                     self->enroll_stage + 1,
                     highest_similarity,
                     EGIS0570_ENROLL_TOO_SIMILAR,
                     EGIS0570_ENROLL_TOO_FAR,
                     self->hold_frame_count);
          fpi_device_enroll_progress (dev, self->enroll_stage, NULL,
                                      fpi_device_retry_new (FP_DEVICE_RETRY_CENTER_FINGER));
          return; /* same height; wait for lift and a neighbour strip */
        }
      else if (strip_spacing == EGIS0570_ENROLL_STRIP_SPACING_TOO_FAR)
        {
          g_message ("enroll section=%d similarity=%.4f too_similar_at=%.2f too_far_at=%.2f hold_frames=%d (slide less, stay near the last strip)",
                     self->enroll_stage + 1,
                     highest_similarity,
                     EGIS0570_ENROLL_TOO_SIMILAR,
                     EGIS0570_ENROLL_TOO_FAR,
                     self->hold_frame_count);
          fpi_device_enroll_progress (dev, self->enroll_stage, NULL,
                                      fpi_device_retry_new (FP_DEVICE_RETRY_CENTER_FINGER));
          return; /* jumped a gap; wait for lift and a closer strip */
        }
      else
        {
          g_message ("enroll section=%d similarity=%.4f too_similar_at=%.2f too_far_at=%.2f hold_frames=%d (store this strip)",
                     self->enroll_stage + 1,
                     highest_similarity,
                     EGIS0570_ENROLL_TOO_SIMILAR,
                     EGIS0570_ENROLL_TOO_FAR,
                     self->hold_frame_count);
          for (hold_index = 0; hold_index < self->hold_frame_count; hold_index++)
            {
              GVariant *next_gallery;

              egis0570_ridge_subtract_background (self->hold_frames[hold_index],
                                                  self->background,
                                                  subtracted,
                                                  EGIS0570_IMGSIZE);
              next_gallery = append_frame_to_print_data (
                updated != NULL ? updated : existing,
                subtracted);
              if (updated != NULL)
                {
                  g_variant_unref (updated);
                }
              else
                {
                  /* first burst of this section; existing stays on autoptr */
                }
              updated = g_variant_ref_sink (next_gallery);
            }
          g_object_set (print, "fpi-data", updated, NULL);
          if (updated != NULL)
            {
              g_variant_unref (updated);
            }
          else
            {
              /* hold_frame_count was already checked above */
            }

          self->enroll_stage += 1;
          fpi_device_enroll_progress (dev, self->enroll_stage, print, NULL);

          if (self->enroll_stage >= EGIS0570_ENROLL_STAGES)
            {
              self->action_reported = TRUE;
              fpi_device_enroll_complete (dev, g_object_ref (print), NULL);
              self->cancelling = TRUE;
            }
          else
            {
              /* more fingertip strips remain */
            }
        }
    }
  else if (action == FPI_DEVICE_ACTION_VERIFY)
    {
      FpPrint *template = NULL;
      g_autoptr(GVariant) gallery = NULL;
      double best_score = -1.0;
      guint8 best_subtracted[EGIS0570_IMGSIZE];
      int hold_index;

      fpi_device_get_verify_data (dev, &template);
      g_object_get (template, "fpi-data", &gallery, NULL);
      memset (best_subtracted, 0, EGIS0570_IMGSIZE);
      for (hold_index = 0; hold_index < self->hold_frame_count; hold_index++)
        {
          double score;

          egis0570_ridge_subtract_background (self->hold_frames[hold_index],
                                              self->background,
                                              subtracted,
                                              EGIS0570_IMGSIZE);
          score = best_score_against_template (subtracted, gallery);
          if (score > best_score)
            {
              best_score = score;
              memcpy (best_subtracted, subtracted, EGIS0570_IMGSIZE);
            }
          else
            {
              /* this burst scored lower */
            }
        }
      log_match_attempt ("verify", best_score, gallery, best_subtracted,
                         self->hold_frame_count);
      if (best_score >= EGIS0570_MATCH_THRESHOLD)
        complete_verify_or_identify (dev, FPI_MATCH_SUCCESS, NULL);
      else
        complete_verify_or_identify (dev, FPI_MATCH_FAIL, NULL);
      self->cancelling = TRUE;
    }
  else if (action == FPI_DEVICE_ACTION_IDENTIFY)
    {
      GPtrArray *templates = NULL;
      guint template_index;
      FpPrint *matched = NULL;
      double best_score = -1.0;
      guint8 best_subtracted[EGIS0570_IMGSIZE];
      int hold_index;

      fpi_device_get_identify_data (dev, &templates);
      memset (best_subtracted, 0, EGIS0570_IMGSIZE);
      for (hold_index = 0; hold_index < self->hold_frame_count; hold_index++)
        {
          egis0570_ridge_subtract_background (self->hold_frames[hold_index],
                                              self->background,
                                              subtracted,
                                              EGIS0570_IMGSIZE);
          for (template_index = 0; templates && template_index < templates->len; template_index++)
            {
              FpPrint *template = g_ptr_array_index (templates, template_index);
              g_autoptr(GVariant) gallery = NULL;
              double score;

              g_object_get (template, "fpi-data", &gallery, NULL);
              score = best_score_against_template (subtracted, gallery);
              if (score > best_score)
                {
                  best_score = score;
                  matched = template;
                  memcpy (best_subtracted, subtracted, EGIS0570_IMGSIZE);
                }
              else
                {
                  /* this template scored lower */
                }
            }
        }

      log_match_attempt ("identify", best_score, NULL, best_subtracted,
                         self->hold_frame_count);
      if (best_score >= EGIS0570_MATCH_THRESHOLD)
        complete_verify_or_identify (dev, FPI_MATCH_SUCCESS, matched);
      else
        complete_verify_or_identify (dev, FPI_MATCH_FAIL, NULL);
      self->cancelling = TRUE;
    }
  else
    {
      /* Capture loop is running for an action that does not store a frame. */
    }
}

static void
data_resp_cb (FpiUsbTransfer *transfer,
              FpDevice       *dev,
              gpointer        user_data,
              GError         *error)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);
  gboolean finger;

  (void) user_data;

  if (error)
    {
      fpi_ssm_mark_failed (transfer->ssm, error);
      return;
    }

  if (self->cancelling || fpi_device_action_is_cancelled (dev))
    {
      fpi_ssm_mark_completed (transfer->ssm);
      return;
    }

  if (self->phase == EGIS0570_PHASE_BACKGROUND)
    {
      update_background_from_payload (self, transfer->buffer);
      self->phase = EGIS0570_PHASE_WAIT_FINGER;
      self->pkt_type = EGIS0570_PKT_REPEAT;
      fpi_ssm_next_state (transfer->ssm);
      return;
    }

  finger = payload_has_finger (self, transfer->buffer);

  if (self->phase == EGIS0570_PHASE_WAIT_FINGER)
    {
      if (finger)
        {
          fpi_device_report_finger_status_changes (dev,
                                                   FP_FINGER_STATUS_PRESENT,
                                                   FP_FINGER_STATUS_NONE);
          self->hold_frame_count = 0;
          remember_hold_burst_frame (self, transfer->buffer);
          self->hold_bursts = 1;
          self->phase = EGIS0570_PHASE_HOLD_FINGER;
        }
    }
  else if (self->phase == EGIS0570_PHASE_HOLD_FINGER)
    {
      if (finger)
        {
          remember_hold_burst_frame (self, transfer->buffer);
          self->hold_bursts += 1;
          if (self->hold_bursts >= EGIS0570_HOLD_BURSTS)
            {
              accept_held_frame (dev);
              self->phase = EGIS0570_PHASE_WAIT_LIFT;
            }
        }
      else
        {
          /* Finger left too soon. */
          fpi_device_report_finger_status_changes (dev,
                                                   FP_FINGER_STATUS_NONE,
                                                   FP_FINGER_STATUS_PRESENT);
          if (fpi_device_get_current_action (dev) == FPI_DEVICE_ACTION_ENROLL &&
              !self->action_reported)
            {
              fpi_device_enroll_progress (dev, self->enroll_stage, NULL,
                                          fpi_device_retry_new (FP_DEVICE_RETRY_REMOVE_FINGER));
            }
          self->phase = EGIS0570_PHASE_WAIT_FINGER;
        }
    }
  else if (self->phase == EGIS0570_PHASE_WAIT_LIFT)
    {
      if (!finger)
        {
          fpi_device_report_finger_status_changes (dev,
                                                   FP_FINGER_STATUS_NONE,
                                                   FP_FINGER_STATUS_PRESENT);
          self->phase = EGIS0570_PHASE_WAIT_FINGER;
        }
    }

  if (self->cancelling)
    fpi_ssm_mark_completed (transfer->ssm);
  else
    fpi_ssm_next_state (transfer->ssm);
}

static void
cmd_resp_cb (FpiUsbTransfer *transfer,
             FpDevice       *dev,
             gpointer        user_data,
             GError         *error)
{
  (void) dev;
  (void) user_data;
  if (error)
    fpi_ssm_mark_failed (transfer->ssm, error);
}

static void
send_cmd_req (FpiSsm          *ssm,
              FpDevice        *dev,
              unsigned char   *pkt)
{
  FpiUsbTransfer *transfer = fpi_usb_transfer_new (dev);

  fpi_usb_transfer_fill_bulk_full (transfer, EGIS0570_EPOUT, pkt, EGIS0570_PKTSIZE, NULL);
  transfer->ssm = ssm;
  transfer->short_is_error = TRUE;
  fpi_usb_transfer_submit (transfer, EGIS0570_TIMEOUT,
                           fpi_device_get_cancellable (dev),
                           fpi_ssm_usb_transfer_cb, NULL);
}

static void
recv_cmd_resp (FpiSsm   *ssm,
               FpDevice *dev)
{
  FpiUsbTransfer *transfer = fpi_usb_transfer_new (dev);

  fpi_usb_transfer_fill_bulk (transfer, EGIS0570_EPIN, EGIS0570_PKTSIZE);
  transfer->ssm = ssm;
  fpi_usb_transfer_submit (transfer, EGIS0570_TIMEOUT,
                           fpi_device_get_cancellable (dev),
                           cmd_resp_cb, NULL);
}

static void
recv_data_resp (FpiSsm   *ssm,
                FpDevice *dev)
{
  FpiUsbTransfer *transfer = fpi_usb_transfer_new (dev);

  fpi_usb_transfer_fill_bulk (transfer, EGIS0570_EPIN, EGIS0570_INPSIZE);
  transfer->ssm = ssm;
  transfer->short_is_error = TRUE;
  fpi_usb_transfer_submit (transfer, EGIS0570_TIMEOUT,
                           fpi_device_get_cancellable (dev),
                           data_resp_cb, NULL);
}

static void
ssm_run_state (FpiSsm   *ssm,
               FpDevice *dev)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);

  if (self->cancelling || fpi_device_action_is_cancelled (dev))
    {
      fpi_ssm_mark_completed (ssm);
      return;
    }

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case SM_START:
      self->pkt_num = 0;
      fpi_ssm_next_state (ssm);
      break;

    case SM_REQ:
      if (self->pkt_type == EGIS0570_PKT_INIT)
        send_cmd_req (ssm, dev, init_pkts[self->pkt_num]);
      else
        send_cmd_req (ssm, dev, repeat_pkts[self->pkt_num]);
      break;

    case SM_RESP:
      if (!is_last_pkt (dev))
        {
          recv_cmd_resp (ssm, dev);
          self->pkt_num += 1;
          fpi_ssm_jump_to_state (ssm, SM_REQ);
        }
      else
        {
          if (self->pkt_type == EGIS0570_PKT_INIT)
            self->pkt_type = EGIS0570_PKT_REPEAT;
          fpi_ssm_next_state (ssm);
        }
      break;

    case SM_REC_DATA:
      recv_data_resp (ssm, dev);
      break;

    case SM_PAUSE:
      fpi_ssm_jump_to_state_delayed (ssm, SM_START, 30);
      break;

    default:
      g_assert_not_reached ();
    }
}

static void
loop_complete (FpiSsm   *ssm,
               FpDevice *dev,
               GError   *error)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);

  (void) ssm;
  self->running = FALSE;
  self->ssm = NULL;

  if (error && !self->action_reported)
    finish_action_error (dev, error);
  else if (!self->action_reported && fpi_device_action_is_cancelled (dev))
    finish_action_error (dev, g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CANCELLED,
                                                   "Capture cancelled"));
}

static void
start_capture_loop (FpDevice *dev)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);

  self->cancelling = FALSE;
  self->action_reported = FALSE;
  self->pkt_type = EGIS0570_PKT_INIT;
  self->phase = EGIS0570_PHASE_BACKGROUND;
  self->hold_bursts = 0;
  clear_hold_frames (self);
  g_clear_pointer (&self->background, g_free);

  self->ssm = fpi_ssm_new (dev, ssm_run_state, SM_STATES_NUM);
  self->running = TRUE;
  fpi_ssm_start (self->ssm, loop_complete);
}

static void
dev_open (FpDevice *dev)
{
  GError *error = NULL;

  g_usb_device_claim_interface (fpi_device_get_usb_device (dev), 0, 0, &error);
  fpi_device_open_complete (dev, error);
}

static void
dev_close (FpDevice *dev)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);
  GError *error = NULL;

  g_clear_pointer (&self->background, g_free);
  clear_hold_frames (self);
  g_usb_device_release_interface (fpi_device_get_usb_device (dev), 0, 0, &error);
  fpi_device_close_complete (dev, error);
}

static void
dev_enroll (FpDevice *dev)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);

  self->enroll_stage = 0;
  fpi_device_report_finger_status_changes (dev,
                                           FP_FINGER_STATUS_NEEDED,
                                           FP_FINGER_STATUS_NONE);
  start_capture_loop (dev);
}

static void
dev_verify (FpDevice *dev)
{
  fpi_device_report_finger_status_changes (dev,
                                           FP_FINGER_STATUS_NEEDED,
                                           FP_FINGER_STATUS_NONE);
  start_capture_loop (dev);
}

static void
dev_identify (FpDevice *dev)
{
  fpi_device_report_finger_status_changes (dev,
                                           FP_FINGER_STATUS_NEEDED,
                                           FP_FINGER_STATUS_NONE);
  start_capture_loop (dev);
}

static void
dev_cancel (FpDevice *dev)
{
  FpDeviceEgis0570 *self = FPI_DEVICE_EGIS0570 (dev);

  self->cancelling = TRUE;
}

static const FpIdEntry id_table[] = {
  { .vid = 0x1c7a, .pid = 0x0570, },
  { .vid = 0x1c7a, .pid = 0x0571, },
  { .vid = 0,      .pid = 0, },
};

static void
fpi_device_egis0570_init (FpDeviceEgis0570 *self)
{
  (void) self;
}

static void
fpi_device_egis0570_class_init (FpDeviceEgis0570Class *klass)
{
  FpDeviceClass *dev_class = FP_DEVICE_CLASS (klass);

  dev_class->id = "egis0570";
  dev_class->full_name = "Egis Technology Inc. (aka. LighTuning) 0570";
  dev_class->type = FP_DEVICE_TYPE_USB;
  dev_class->id_table = id_table;
  dev_class->nr_enroll_stages = EGIS0570_ENROLL_STAGES;
  dev_class->scan_type = FP_SCAN_TYPE_PRESS;
  dev_class->temp_hot_seconds = -1;
  dev_class->temp_cold_seconds = -1;

  dev_class->open = dev_open;
  dev_class->close = dev_close;
  dev_class->enroll = dev_enroll;
  dev_class->verify = dev_verify;
  dev_class->identify = dev_identify;
  dev_class->cancel = dev_cancel;

  fpi_device_class_auto_initialize_features (dev_class);
}
