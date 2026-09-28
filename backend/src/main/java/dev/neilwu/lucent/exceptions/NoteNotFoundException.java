package dev.neilwu.lucent.exceptions;

public class NoteNotFoundException extends RuntimeException{

    private final Long noteId;

    public NoteNotFoundException(Long noteId) {
        this.noteId = noteId;
    }

    public Long getNoteId()
    {
        return noteId;
    }
}
