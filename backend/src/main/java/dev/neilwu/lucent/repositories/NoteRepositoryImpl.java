package dev.neilwu.lucent.repositories;

import dev.neilwu.lucent.models.Note;
import dev.neilwu.lucent.repositories.interfaces.NoteRepository;
import dev.neilwu.lucent.repositories.persistence.entities.NoteJpaEntity;
import dev.neilwu.lucent.repositories.persistence.mappers.NotePersistenceMapper;
import dev.neilwu.lucent.repositories.persistence.springdata.SpringDataNoteRepository;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

@Repository
public class NoteRepositoryImpl implements NoteRepository {

    private final SpringDataNoteRepository springDataNoteRepository;
    private final NotePersistenceMapper notePersistenceMapper;

    public NoteRepositoryImpl(
            SpringDataNoteRepository springDataNoteRepository,
            NotePersistenceMapper notePersistenceMapper
    ) {
        this.springDataNoteRepository = springDataNoteRepository;
        this.notePersistenceMapper = notePersistenceMapper;
    }

    @Override
    public Note save(Note note) {
        NoteJpaEntity entity = notePersistenceMapper.toEntity(note);
        NoteJpaEntity savedEntity = springDataNoteRepository.save(entity);

        return notePersistenceMapper.toModel(savedEntity);
    }

    @Override
    public List<Note> findAll() {
        return springDataNoteRepository.findAll()
                .stream()
                .map(notePersistenceMapper::toModel)
                .toList();
    }

    @Override
    public Optional<Note> findById(Long Id) {
        return springDataNoteRepository.findById(Id)
                .map(notePersistenceMapper::toModel);
    }

    @Override
    public void deleteById(Long Id) {
        springDataNoteRepository.deleteById(Id);
    }
}
