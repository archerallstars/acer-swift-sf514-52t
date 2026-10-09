/*
 * USB protocol constants for the EgisTec (LighTuning) 1c7a:0570
 * fingerprint pad on the Acer Swift SF514-52T.
 *
 * Command packets are 7 bytes: ASCII "EGIS" plus command, register,
 * and value. Replies to register writes are 7 bytes starting with
 * ASCII "SIGE". The capture command (0x06) replies with a 32512-byte
 * image payload instead: five 114 by 57 frames plus 22 trailing bytes.
 */

#ifndef SF514_EGIS0570_PROTOCOL_H
#define SF514_EGIS0570_PROTOCOL_H 1

#include <stdint.h>

/* USB identity of this laptop's pad. */
#define SF514_EGIS0570_USB_VENDOR_ID 0x1c7au
#define SF514_EGIS0570_USB_PRODUCT_ID 0x0570u

/* Bulk endpoints and the only interface the pad exposes. */
#define SF514_EGIS0570_USB_CONFIGURATION_VALUE 1
#define SF514_EGIS0570_USB_INTERFACE_NUMBER 0
#define SF514_EGIS0570_USB_BULK_OUT_ENDPOINT 0x04
#define SF514_EGIS0570_USB_BULK_IN_ENDPOINT 0x83

/* Transfer and packet sizes. */
#define SF514_EGIS0570_TRANSFER_TIMEOUT_MILLISECONDS 10000
#define SF514_EGIS0570_COMMAND_PACKET_SIZE_BYTES 7
#define SF514_EGIS0570_CAPTURE_PAYLOAD_SIZE_BYTES 32512

/* Five frames of 114 by 57 = 6498 bytes; 5 * 6498 = 32490, plus 22 extra. */
#define SF514_EGIS0570_FRAME_WIDTH_PIXELS 114
#define SF514_EGIS0570_FRAME_HEIGHT_PIXELS 57
#define SF514_EGIS0570_FRAME_SIZE_BYTES \
  (SF514_EGIS0570_FRAME_WIDTH_PIXELS * SF514_EGIS0570_FRAME_HEIGHT_PIXELS)
#define SF514_EGIS0570_FRAME_COUNT_PER_CAPTURE 5
#define SF514_EGIS0570_CAPTURE_TRAILER_SIZE_BYTES \
  (SF514_EGIS0570_CAPTURE_PAYLOAD_SIZE_BYTES \
   - (SF514_EGIS0570_FRAME_COUNT_PER_CAPTURE * SF514_EGIS0570_FRAME_SIZE_BYTES))

#endif
