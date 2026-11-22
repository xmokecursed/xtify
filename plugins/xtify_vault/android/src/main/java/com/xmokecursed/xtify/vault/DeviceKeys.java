package com.xmokecursed.xtify.vault;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.security.Key;
import java.security.KeyStore;

import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;

/** The AES-GCM key kept inside the Android Keystore. */
final class DeviceKeys implements KeyBox.Keys {
    private static final String PROVIDER = "AndroidKeyStore";
    private static final String ALIAS = "xtify_vault_master_v1";

    @Override
    public SecretKey find() throws Exception {
        KeyStore store = KeyStore.getInstance(PROVIDER);
        store.load(null);
        Key key = store.getKey(ALIAS, null);
        return key instanceof SecretKey ? (SecretKey) key : null;
    }

    @Override
    public SecretKey create() throws Exception {
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER);
        generator.init(
                new KeyGenParameterSpec.Builder(
                                ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build());
        return generator.generateKey();
    }
}
