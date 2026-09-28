package dev.neilwu.lucent.services.interfaces;

import java.util.List;

import dev.neilwu.lucent.models.Note;

public interface NoteService {

    Note createNote(String title);

    List<Note> getAllNotes();

    Note changeNoteTitle(Long Id, String newTitle);

    void deleteNote(Long id);

}
