package dev.neilwu.lucent.exceptions;

public class InvalidNoteIdException extends RuntimeException {

    private final  Long noteId;

    public InvalidNoteIdException(Long noteId)
    {
        this.noteId = noteId;
    }

    public Long getNoteId()
    {
        return noteId;
    }
}
