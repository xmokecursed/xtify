package com.xmokecursed.xtify.vault;

import java.util.Arrays;

import javax.crypto.BadPaddingException;
import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Wraps and unwraps the 32 byte master key of the app with an AES-GCM key that never leaves
 * the Android Keystore. The wrapped blob is [version][iv length][iv][encrypted key + tag].
 */
final class KeyBox {
    interface Keys {
        /** The key, or null when there is none yet. Never creates one. */
        SecretKey find() throws Exception;

        SecretKey create() throws Exception;
    }

    private static final String TRANSFORMATION = "AES/GCM/NoPadding";
    private static final int TAG_BITS = 128;
    private static final int IV_MIN = 12;
    private static final int IV_MAX = 16;
    private static final byte VERSION = 1;
    private static final Object LOCK = new Object();

    private final Keys keys;

    KeyBox(Keys keys) {
        this.keys = keys;
    }

    byte[] wrap(byte[] plain) throws Exception {
        if (plain == null || plain.length == 0) {
            throw new KeyBoxException("bad_arguments", "there is nothing to protect");
        }
        synchronized (LOCK) {
            SecretKey key = keys.find();
            if (key == null) key = keys.create();
            Cipher cipher = Cipher.getInstance(TRANSFORMATION);
            cipher.init(Cipher.ENCRYPT_MODE, key);
            byte[] iv = cipher.getIV();
            if (iv == null || iv.length < IV_MIN || iv.length > IV_MAX) {
                throw new KeyBoxException("keystore", "the key store gave an unexpected nonce");
            }
            byte[] sealed = cipher.doFinal(plain);
            byte[] out = new byte[2 + iv.length + sealed.length];
            out[0] = VERSION;
            out[1] = (byte) iv.length;
            System.arraycopy(iv, 0, out, 2, iv.length);
            System.arraycopy(sealed, 0, out, 2 + iv.length, sealed.length);
            return out;
        }
    }

    byte[] unwrap(byte[] blob) throws Exception {
        if (blob == null || blob.length < 2 + IV_MIN + 16 || blob[0] != VERSION) {
            throw new KeyBoxException("bad_blob", "the saved key is not in a known format");
        }
        int ivLength = blob[1] & 0xFF;
        if (ivLength < IV_MIN || ivLength > IV_MAX || blob.length < 2 + ivLength + 16) {
            throw new KeyBoxException("bad_blob", "the saved key is not in a known format");
        }
        byte[] iv = Arrays.copyOfRange(blob, 2, 2 + ivLength);
        byte[] sealed = Arrays.copyOfRange(blob, 2 + ivLength, blob.length);
        synchronized (LOCK) {
            SecretKey key = keys.find();
            if (key == null) {
                throw new KeyBoxException("key_missing", "the key store has no key for this app");
            }
            Cipher cipher = Cipher.getInstance(TRANSFORMATION);
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(TAG_BITS, iv));
            try {
                return cipher.doFinal(sealed);
            } catch (BadPaddingException e) {
                // The key store has a key, but not the one that sealed this blob.
                throw new KeyBoxException(
                        "key_mismatch", "the key store key does not open the saved key");
            }
        }
    }
}
