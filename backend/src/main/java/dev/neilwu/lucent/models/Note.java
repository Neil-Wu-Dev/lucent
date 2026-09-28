package dev.neilwu.lucent.models;

import dev.neilwu.lucent.exceptions.InvalidNoteIdException;
import dev.neilwu.lucent.exceptions.InvalidNoteTitleException;

public class Note {

    private static final int MAX_TITLE_LENGTH = 100;

    private final Long id;
    private String title;

    private Note(Long id, String title)
    {
        this.id = id;
        this.title = title;
    }


    public static Note create(String title)
    {
        validateTitle(title);

        return new Note(null, title);
    }

    public static Note restore(Long id, String title)
    {
        validateId(id);
        validateTitle(title);

        return new Note(id, title);
    }

    public void changeTitle(String newTitle)
    {
        validateTitle(newTitle);

        this.title = newTitle;
    }

    public Long getId()
    {
        return id;
    }
    public String getTitle()
    {
        return title;
    }

    private static void validateId(Long id)
    {
        if (id == null || id <= 0)
        {
            throw new InvalidNoteIdException(id);
        }
    }

    private  static void validateTitle(String title)
    {
        if(title != null && title.length() > MAX_TITLE_LENGTH)
        {
            throw new InvalidNoteTitleException(
                    MAX_TITLE_LENGTH,
                    title.length()
            );
        }
    }


}
