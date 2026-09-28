package dev.neilwu.lucent.repositories.interfaces;

import java.util.List;
import java.util.Optional;

import dev.neilwu.lucent.models.Note;

public interface NoteRepository {
    Note save(Note note);

    List<Note> findAll();

    Optional<Note> findById(Long Id);

    void deleteById(Long Id);
}
