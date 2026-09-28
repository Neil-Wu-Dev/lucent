package dev.neilwu.lucent.repositories.persistence.springdata;

import dev.neilwu.lucent.repositories.persistence.entities.NoteJpaEntity;
import org.springframework.data.jpa.repository.JpaRepository;

public interface SpringDataNoteRepository extends JpaRepository<NoteJpaEntity, Long> {
}
