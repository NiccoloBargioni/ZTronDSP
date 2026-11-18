/* Fixture of WP-201. A non-blocking function that calls a vDSP entry point the allow-list does
   not name: creating a setup, which allocates and belongs to the control context. With the
   flags the manifest gives the C target this file MUST NOT build. */

#include "ztd_vdsp.h"

vDSP_DFT_Setup ztd_fixture_unlisted(uint32_t length) ZTD_NONBLOCKING {
    return vDSP_DFT_zrop_CreateSetup(NULL, length, vDSP_DFT_FORWARD);
}
