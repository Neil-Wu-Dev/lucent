package dev.neilwu.lucent.exceptions;

public class InvalidNoteTitleException extends RuntimeException{

    private final int maxLength;
    private final int actualLength;

    public InvalidNoteTitleException(int maxLength,int actualLength)
    {
        this.maxLength = maxLength;
        this.actualLength = actualLength;
    }

    public int getMaxLength()
    {
        return maxLength;
    }

    public int getActualLength()
    {
        return actualLength;
    }
}
