"""Shared release failures; every gate stops publication."""

class ReleaseError(Exception):
    pass


class NotarizationError(ReleaseError):
    pass
