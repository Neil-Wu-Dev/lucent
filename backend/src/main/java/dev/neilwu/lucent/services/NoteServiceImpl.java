package dev.neilwu.lucent.services;

import dev.neilwu.lucent.exceptions.NoteNotFoundException;
import dev.neilwu.lucent.models.Note;
import dev.neilwu.lucent.repositories.interfaces.NoteRepository;
import dev.neilwu.lucent.services.interfaces.NoteService;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class NoteServiceImpl implements NoteService {

    private final NoteRepository noteRepository;

    public NoteServiceImpl(NoteRepository noteRepository) {
        this.noteRepository = noteRepository;
    }

    @Override
    public Note createNote(String title) {
        Note note = Note.create(title);

        return noteRepository.save(note);
    }

    @Override
    public List<Note> getAllNotes() {
        return noteRepository.findAll();
    }

    @Override
    public Note changeNoteTitle(Long id, String newTitle) {
        Note note = noteRepository.findById(id)
                .orElseThrow(() -> new NoteNotFoundException(id));

        note.changeTitle(newTitle);

        return noteRepository.save(note);
    }

    @Override
    public void deleteNote(Long id) {
        Note note = noteRepository.findById(id)
                .orElseThrow(() -> new NoteNotFoundException(id));

        noteRepository.deleteById(note.getId());
    }
}