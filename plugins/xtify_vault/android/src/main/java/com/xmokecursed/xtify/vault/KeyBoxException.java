package com.xmokecursed.xtify.vault;

final class KeyBoxException extends Exception {
    private static final long serialVersionUID = 1L;

    final String code;

    KeyBoxException(String code, String message) {
        super(message);
        this.code = code;
    }
}
