package dev.neilwu.lucent.api.exception;

import dev.neilwu.lucent.exceptions.InvalidNoteIdException;
import dev.neilwu.lucent.exceptions.InvalidNoteTitleException;
import dev.neilwu.lucent.exceptions.NoteNotFoundException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(NoteNotFoundException.class)
    public ProblemDetail handleNoteNotFound(NoteNotFoundException exception)
    {
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.NOT_FOUND);

        problem.setTitle("Note not found");
        problem.setDetail(
                "Note with id " + exception.getNoteId() + " does not exist."
        );

        return problem;
    }

    @ExceptionHandler(InvalidNoteIdException.class)
    public ProblemDetail handleInvalidNoteId(InvalidNoteIdException exception)
    {
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.BAD_REQUEST);

        problem.setTitle("Invalid note id");
        problem.setDetail(
                "Note id must be greater than 0."
        );

        return problem;
    }

    @ExceptionHandler(InvalidNoteTitleException.class)
    public ProblemDetail handleInvalidNoteTitle(InvalidNoteTitleException exception)
    {
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.BAD_REQUEST);

        problem.setTitle("Invalid note title");
        problem.setDetail(
                "Note title cannot exceed "
                        + exception.getMaxLength()
                        + " characters."
        );

        return problem;
    }
}