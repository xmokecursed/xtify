#ifndef RUNNER_VAULT_CHANNEL_H_
#define RUNNER_VAULT_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

#include <memory>

// Lets the app keep the key that protects its saved data with Windows (DPAPI),
// so only the signed-in Windows user can unlock it.
class VaultChannel {
 public:
  explicit VaultChannel(flutter::BinaryMessenger* messenger);
  ~VaultChannel();

  VaultChannel(const VaultChannel&) = delete;
  VaultChannel& operator=(const VaultChannel&) = delete;

 private:
  void Handle(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_VAULT_CHANNEL_H_
