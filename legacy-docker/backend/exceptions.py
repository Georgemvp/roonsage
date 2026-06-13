"""Custom exceptions for RoonSage.

A small hierarchy that lets routers/services raise meaningful errors and have
them rendered as consistent JSON responses by the global exception handler in
backend.main.
"""


class RoonSageError(Exception):
    """Base exception for all RoonSage errors."""

    status_code: int = 500

    def __init__(self, message: str, status_code: int | None = None):
        self.message = message
        if status_code is not None:
            self.status_code = status_code
        super().__init__(message)


class RoonConnectionError(RoonSageError):
    """Raised when the Roon Core is unreachable or not yet authorized."""

    status_code = 503

    def __init__(self, message: str = "Roon Core not connected"):
        super().__init__(message)


class LLMProviderError(RoonSageError):
    """Raised when the configured LLM provider fails or is misconfigured."""

    status_code = 502

    def __init__(self, message: str = "LLM provider error"):
        super().__init__(message)


class EnrichmentError(RoonSageError):
    """Raised when MusicBrainz/Last.fm enrichment fails."""

    status_code = 500

    def __init__(self, message: str = "Enrichment failed"):
        super().__init__(message)


class LibrarySyncError(RoonSageError):
    """Raised when a Roon library sync cannot complete."""

    status_code = 500

    def __init__(self, message: str = "Library sync failed"):
        super().__init__(message)
