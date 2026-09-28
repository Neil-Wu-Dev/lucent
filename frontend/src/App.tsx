import { useCallback, useEffect, useState } from 'react'
import type { FormEvent, MouseEvent } from 'react'
import './App.css'

type Note = {
  id: number
  title: string | null
}

type ApiProblem = {
  title?: string
  detail?: string
  status?: number
}

type BackendStatus = 'checking' | 'online' | 'offline'

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:8080'
const NOTES_ENDPOINT = `${API_BASE_URL}/api/v1/notes`

async function readResponse<T>(response: Response): Promise<T> {
  const text = await response.text()
  const data = text ? JSON.parse(text) : null

  if (!response.ok) {
    const problem = data as ApiProblem | null
    const detail = problem?.detail ?? text ?? response.statusText
    const title = problem?.title ? `${problem.title}: ` : ''

    throw new Error(`${response.status} ${response.statusText}. ${title}${detail}`)
  }

  return data as T
}

function App() {
  const [notes, setNotes] = useState<Note[]>([])
  const [newTitle, setNewTitle] = useState('')
  const [selectedNote, setSelectedNote] = useState<Note | null>(null)
  const [editingTitle, setEditingTitle] = useState('')
  const [successMessage, setSuccessMessage] = useState('')
  const [errorMessage, setErrorMessage] = useState('')
  const [isLoading, setIsLoading] = useState(true)
  const [backendStatus, setBackendStatus] = useState<BackendStatus>('checking')
  const [backendStatusDetail, setBackendStatusDetail] = useState(
    `Checking ${NOTES_ENDPOINT}`,
  )

  const request = useCallback(async function request<T>(
    input: RequestInfo,
    init?: RequestInit,
  ): Promise<T> {
    try {
      const response = await fetch(input, {
        headers: {
          'Content-Type': 'application/json',
          ...init?.headers,
        },
        ...init,
      })

      return await readResponse<T>(response)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      setErrorMessage(message)
      throw error
    }
  }, [])

  useEffect(() => {
    let isCurrent = true

    fetch(NOTES_ENDPOINT, {
      headers: {
        'Content-Type': 'application/json',
      },
    })
      .then((response) => readResponse<Note[]>(response))
      .then((nextNotes) => {
        if (isCurrent) {
          setNotes(nextNotes)
          setBackendStatus('online')
          setBackendStatusDetail(`Connected to ${API_BASE_URL}`)
        }
      })
      .catch((error) => {
        if (isCurrent) {
          const message = error instanceof Error ? error.message : String(error)
          setBackendStatus('offline')
          setBackendStatusDetail(message)
          setErrorMessage(message)
        }
      })
      .finally(() => {
        if (isCurrent) {
          setIsLoading(false)
        }
      })

    return () => {
      isCurrent = false
    }
  }, [])

  async function createNote(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const title = newTitle.trim()

    try {
      const createdNote = await request<Note>(NOTES_ENDPOINT, {
        method: 'POST',
        body: JSON.stringify({ title }),
      })

      setNotes((currentNotes) => [...currentNotes, createdNote])
      setNewTitle('')
      setSuccessMessage('Note created successfully.')
    } catch {
      return
    }
  }

  function openNote(note: Note) {
    setSelectedNote(note)
    setEditingTitle(note.title ?? '')
  }

  async function saveSelectedNote() {
    if (!selectedNote) {
      return
    }

    try {
      const updatedNote = await request<Note>(`${NOTES_ENDPOINT}/${selectedNote.id}`, {
        method: 'PATCH',
        body: JSON.stringify({ title: editingTitle }),
      })

      setNotes((currentNotes) =>
        currentNotes.map((note) => (note.id === updatedNote.id ? updatedNote : note)),
      )
      setSelectedNote(updatedNote)
      setEditingTitle(updatedNote.title ?? '')
      setSuccessMessage('Note updated successfully.')
    } catch {
      return
    }
  }

  async function deleteNote(noteId: number) {
    try {
      await request<void>(`${NOTES_ENDPOINT}/${noteId}`, {
        method: 'DELETE',
      })

      setNotes((currentNotes) => currentNotes.filter((note) => note.id !== noteId))
      setSelectedNote((currentNote) => (currentNote?.id === noteId ? null : currentNote))
      setSuccessMessage('Note deleted successfully.')
    } catch {
      return
    }
  }

  function deleteFromCard(event: MouseEvent<HTMLButtonElement>, noteId: number) {
    event.stopPropagation()
    deleteNote(noteId)
  }

  return (
    <main className="lucent-shell">
      <header className="top-bar">
        <a className="brand" href="/" aria-label="Lucent home">
          Lucent
        </a>
      </header>

      <section className="composer-section" aria-label="Create note">
        {successMessage && <p className="success-message">{successMessage}</p>}

        {errorMessage && (
          <div className="error-panel" role="alert">
            <p>{errorMessage}</p>
            <button
              type="button"
              className="icon-button"
              aria-label="Close error message"
              onClick={() => setErrorMessage('')}
            >
              x
            </button>
          </div>
        )}

        <form className="note-form" onSubmit={createNote}>
          <input
            value={newTitle}
            placeholder="Add Note"
            aria-label="Add Note"
            onChange={(event) => setNewTitle(event.target.value)}
          />
          <button type="submit">Add</button>
        </form>
      </section>

      <section className="notes-board" aria-label="Notes">
        {isLoading && <p className="board-message">Loading notes...</p>}

        {!isLoading && notes.length === 0 && (
          <p className="board-message">No notes yet.</p>
        )}

        {notes.map((note) => (
          <article
            className="note-card"
            key={note.id}
            tabIndex={0}
            onClick={() => openNote(note)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                openNote(note)
              }
            }}
          >
            <p>{note.title}</p>
            <button
              type="button"
              className="delete-button"
              onClick={(event) => deleteFromCard(event, note.id)}
            >
              Delete
            </button>
          </article>
        ))}
      </section>

      {selectedNote && (
        <section className="note-window" aria-label="Selected note">
          <div className="window-header">
            <span>Note #{selectedNote.id}</span>
            <button
              type="button"
              className="icon-button"
              aria-label="Close note"
              onClick={() => setSelectedNote(null)}
            >
              x
            </button>
          </div>

          <textarea
            value={editingTitle}
            aria-label="Note title"
            onChange={(event) => setEditingTitle(event.target.value)}
          />

          <div className="window-actions">
            <button type="button" onClick={saveSelectedNote}>
              Save Changes
            </button>
            <button
              type="button"
              className="delete-button"
              onClick={() => deleteNote(selectedNote.id)}
            >
              Delete
            </button>
          </div>
        </section>
      )}

      <aside
        className={`backend-status backend-status--${backendStatus}`}
        aria-label="Backend connection status"
      >
        <span className="status-dot" aria-hidden="true" />
        <div>
          <strong>
            {backendStatus === 'checking' && 'Checking backend'}
            {backendStatus === 'online' && 'Backend connected'}
            {backendStatus === 'offline' && 'Backend unavailable'}
          </strong>
          <p>{backendStatusDetail}</p>
        </div>
      </aside>
    </main>
  )
}

export default App
