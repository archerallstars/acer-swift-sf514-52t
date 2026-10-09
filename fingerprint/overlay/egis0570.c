/*
 * Egis Technology Inc. (aka. LighTuning) 0570 driver for libfprint
 *
 * Press-mode overlay for USB 1c7a:0570 / 1c7a:0571. Host-side matching
 * stores 114x57 frames as FPI_PRINT_RAW and scores them with the
 * clean-room Gabor/NCC matcher in egis0570-ridge.c.
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
  guint8  *best_frame;
  double   best_stddev;
};

G_DECLARE_FINAL_TYPE (FpDeviceEgis0570, fpi_device_egis0570, FPI, DEVICE_EGIS0570, FpDevice);
G_DEFINE_TYPE (FpDeviceEgis0570, fpi_device_egis0570, FP_TYPE_DEVICE);

static void loop_complete (FpiSsm *ssm, FpDevice *dev, GError *error);
static void ssm_run_state (FpiSsm *ssm, FpDevice *dev);
static void start_capture_loop (FpDevice *dev);

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

static void
remember_best_frame (FpDeviceEgis0570 *self,
                     const guint8     *payload)
{
  guint8 candidate[EGIS0570_IMGSIZE];
  guint8 subtracted[EGIS0570_IMGSIZE];
  double mean_value;
  double stddev_value;

  egis0570_ridge_pick_best_frame (payload,
                                  self->background,
                                  candidate,
                                  EGIS0570_IMGSIZE,
                                  EGIS0570_IMGCOUNT);
  egis0570_ridge_subtract_background (candidate,
                                      self->background,
                                      subtracted,
                                      EGIS0570_IMGSIZE);
  mean_value = egis0570_ridge_frame_mean (subtracted, EGIS0570_IMGSIZE);
  stddev_value = egis0570_ridge_frame_stddev (subtracted, EGIS0570_IMGSIZE, mean_value);

  if (!self->best_frame)
    self->best_frame = g_malloc (EGIS0570_IMGSIZE);

  if (stddev_value >= self->best_stddev)
    {
      memcpy (self->best_frame, candidate, EGIS0570_IMGSIZE);
      self->best_stddev = stddev_value;
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
    return best_score;

  for (child_index = 0; child_index < g_variant_n_children (gallery); child_index++)
    {
      g_autoptr(GVariant) child = g_variant_get_child_value (gallery, child_index);
      gsize length = 0;
      const guint8 *gallery_bytes;
      double score;

      gallery_bytes = g_variant_get_fixed_array (child, &length, 1);
      if (!gallery_bytes || length != EGIS0570_IMGSIZE)
        continue;

      score = egis0570_ridge_match_score (probe_bytes,
                                          gallery_bytes,
                                          EGIS0570_IMGWIDTH,
                                          EGIS0570_IMGHEIGHT);
      if (score > best_score)
        best_score = score;
    }

  return best_score;
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

  if (!self->best_frame)
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

  egis0570_ridge_subtract_background (self->best_frame,
                                      self->background,
                                      subtracted,
                                      EGIS0570_IMGSIZE);

  if (action == FPI_DEVICE_ACTION_ENROLL)
    {
      FpPrint *print = NULL;
      g_autoptr(GVariant) existing = NULL;
      GVariant *updated;

      fpi_device_get_enroll_data (dev, &print);
      if (self->enroll_stage == 0)
        fpi_print_set_type (print, FPI_PRINT_RAW);
      g_object_get (print, "fpi-data", &existing, NULL);
      updated = append_frame_to_print_data (existing, subtracted);
      g_object_set (print, "fpi-data", updated, NULL);

      self->enroll_stage += 1;
      fpi_device_enroll_progress (dev, self->enroll_stage, print, NULL);

      if (self->enroll_stage >= EGIS0570_ENROLL_STAGES)
        {
          self->action_reported = TRUE;
          fpi_device_enroll_complete (dev, g_object_ref (print), NULL);
          self->cancelling = TRUE;
        }
    }
  else if (action == FPI_DEVICE_ACTION_VERIFY)
    {
      FpPrint *template = NULL;
      g_autoptr(GVariant) gallery = NULL;
      double score;

      fpi_device_get_verify_data (dev, &template);
      g_object_get (template, "fpi-data", &gallery, NULL);
      score = best_score_against_template (subtracted, gallery);
      fp_dbg ("verify score=%f threshold=%f", score, EGIS0570_MATCH_THRESHOLD);
      if (score >= EGIS0570_MATCH_THRESHOLD)
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

      fpi_device_get_identify_data (dev, &templates);
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
            }
        }

      fp_dbg ("identify score=%f threshold=%f", best_score, EGIS0570_MATCH_THRESHOLD);
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
          self->best_stddev = -1.0;
          g_clear_pointer (&self->best_frame, g_free);
          remember_best_frame (self, transfer->buffer);
          self->hold_bursts = 1;
          self->phase = EGIS0570_PHASE_HOLD_FINGER;
        }
    }
  else if (self->phase == EGIS0570_PHASE_HOLD_FINGER)
    {
      if (finger)
        {
          remember_best_frame (self, transfer->buffer);
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
  self->best_stddev = -1.0;
  g_clear_pointer (&self->best_frame, g_free);
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
  g_clear_pointer (&self->best_frame, g_free);
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
