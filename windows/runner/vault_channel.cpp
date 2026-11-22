#include "vault_channel.h"

#include <windows.h>
#include <wincrypt.h>
#include <dpapi.h>

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

constexpr size_t kMaxInput = 4096;

// "xtify-vault-v1". Mixed into the protection so that another program's DPAPI
// blob is not accepted as ours.
const BYTE kEntropy[] = {0x78, 0x74, 0x69, 0x66, 0x79, 0x2d, 0x76,
                         0x61, 0x75, 0x6c, 0x74, 0x2d, 0x76, 0x31};

bool Protect(const std::vector<uint8_t>& plain, std::vector<uint8_t>* out,
             DWORD* error) {
  DATA_BLOB input = {static_cast<DWORD>(plain.size()),
                     const_cast<BYTE*>(plain.data())};
  DATA_BLOB entropy = {static_cast<DWORD>(sizeof(kEntropy)),
                       const_cast<BYTE*>(kEntropy)};
  DATA_BLOB sealed = {0, nullptr};
  if (!CryptProtectData(&input, L"Xtify saved data key", &entropy, nullptr,
                        nullptr, CRYPTPROTECT_UI_FORBIDDEN, &sealed)) {
    *error = GetLastError();
    return false;
  }
  out->assign(sealed.pbData, sealed.pbData + sealed.cbData);
  LocalFree(sealed.pbData);
  return true;
}

bool Unprotect(const std::vector<uint8_t>& sealed, std::vector<uint8_t>* out,
               DWORD* error) {
  DATA_BLOB input = {static_cast<DWORD>(sealed.size()),
                     const_cast<BYTE*>(sealed.data())};
  DATA_BLOB entropy = {static_cast<DWORD>(sizeof(kEntropy)),
                       const_cast<BYTE*>(kEntropy)};
  DATA_BLOB plain = {0, nullptr};
  if (!CryptUnprotectData(&input, nullptr, &entropy, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &plain)) {
    *error = GetLastError();
    return false;
  }
  out->assign(plain.pbData, plain.pbData + plain.cbData);
  SecureZeroMemory(plain.pbData, plain.cbData);
  LocalFree(plain.pbData);
  return true;
}

}  // namespace

VaultChannel::VaultChannel(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "xtify/vault",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { Handle(call, std::move(result)); });
}

VaultChannel::~VaultChannel() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void VaultChannel::Handle(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "kind") {
    result->Success(flutter::EncodableValue(std::string("windows-dpapi")));
    return;
  }
  const bool wrap = method == "wrap";
  if (!wrap && method != "unwrap") {
    result->NotImplemented();
    return;
  }
  const auto* bytes = std::get_if<std::vector<uint8_t>>(call.arguments());
  if (bytes == nullptr || bytes->empty() || bytes->size() > kMaxInput) {
    result->Error("bad_arguments", "Expected a small byte array");
    return;
  }
  std::vector<uint8_t> out;
  DWORD error = 0;
  const bool ok = wrap ? Protect(*bytes, &out, &error)
                       : Unprotect(*bytes, &out, &error);
  if (!ok) {
    result->Error("dpapi", std::string("Windows could not ") +
                               (wrap ? "protect" : "unlock") +
                               " the key (error " + std::to_string(error) + ")");
    return;
  }
  result->Success(flutter::EncodableValue(std::move(out)));
}
