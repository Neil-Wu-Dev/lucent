package dev.neilwu.lucent.repositories.persistence.mappers;

import dev.neilwu.lucent.models.Note;
import dev.neilwu.lucent.repositories.persistence.entities.NoteJpaEntity;
import org.springframework.stereotype.Component;

@Component
public class NotePersistenceMapper {

    public NoteJpaEntity toEntity(Note note) {
        return new NoteJpaEntity(
                note.getId(),
                note.getTitle()
        );
    }

    public Note toModel(NoteJpaEntity entity) {
        return Note.restore(
                entity.getId(),
                entity.getTitle()
        );
    }
}
