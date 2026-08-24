#ifndef STUPIDWALLET_CSECP256K1_WRAPPER_H
#define STUPIDWALLET_CSECP256K1_WRAPPER_H

#define ENABLE_MODULE_RECOVERY 1
#define ENABLE_MODULE_ECDH 1

#include "../../Sources/CSecp256k1/include/secp256k1.h"
#include "../../Sources/CSecp256k1/include/secp256k1_recovery.h"
#include "../../Sources/CSecp256k1/include/secp256k1_ecdh.h"
#include "../../Sources/CSecp256k1/include/secp256k1_preallocated.h"

#endif