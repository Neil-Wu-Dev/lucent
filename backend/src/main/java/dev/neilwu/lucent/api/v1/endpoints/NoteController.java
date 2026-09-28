package dev.neilwu.lucent.api.v1.endpoints;

import dev.neilwu.lucent.mappers.NoteMapper;
import dev.neilwu.lucent.models.Note;
import dev.neilwu.lucent.schemas.CreateNoteRequest;
import dev.neilwu.lucent.schemas.NoteResponse;
import dev.neilwu.lucent.schemas.UpdateNoteTitleRequest;
import dev.neilwu.lucent.services.interfaces.NoteService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/notes")
public class NoteController {

    private final NoteService noteService;

    public NoteController(NoteService noteService)
    {
        this.noteService = noteService;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public NoteResponse createNote(@RequestBody CreateNoteRequest request)
    {
        Note note = noteService.createNote(request.title());

        return NoteMapper.toResponse(note);
    }

    @GetMapping
    public List<NoteResponse> getAllNotes()
    {
        return noteService.getAllNotes()
                .stream()
                .map(NoteMapper::toResponse)
                .toList();
    }

    @PatchMapping("/{id}")
    public NoteResponse changeNoteTitle(
            @PathVariable Long id,
            @RequestBody UpdateNoteTitleRequest request)
    {
        Note note = noteService.changeNoteTitle(
                id,
                request.title()
        );

        return NoteMapper.toResponse(note);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void deleteNote(@PathVariable Long id)
    {
        noteService.deleteNote(id);
    }
}