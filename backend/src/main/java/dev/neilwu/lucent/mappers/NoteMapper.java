package dev.neilwu.lucent.mappers;

import dev.neilwu.lucent.schemas.NoteResponse;
import dev.neilwu.lucent.schemas.CreateNoteRequest;
import dev.neilwu.lucent.models.Note;

public final class NoteMapper {

    private NoteMapper()
    {
    }

    public static Note toModel(CreateNoteRequest request)
    {
        return Note.create(request.title());
    }

    public static NoteResponse toResponse(Note note)
    {
        return new NoteResponse(
                note.getId(),
                note.getTitle()
        );
    }
}