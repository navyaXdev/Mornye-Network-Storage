"""
backend/core/exceptions.py
Exception hierarchy for Mornye Network Storage.
"""

class MornyeException(Exception):
    """Base exception for Mornye storage system."""
    def __init__(self, message: str, status_code: int = 400):
        super().__init__(message)
        self.message = message
        self.status_code = status_code

class StorageSecurityException(MornyeException):
    """Security violation such as directory traversal or path jail escape."""
    def __init__(self, message: str = "Access forbidden: directory traversal or path jail violation detected"):
        super().__init__(message, status_code=403)

class QuotaExceededException(MornyeException):
    """Storage quota exceeded."""
    def __init__(self, message: str = "Storage quota exceeded: 100 GB music storage limit reached"):
        super().__init__(message, status_code=507)

class NonAudioFileException(MornyeException):
    """Uploaded file is not a supported legitimate audio file."""
    def __init__(self, message: str = "Unsupported media type: only legitimate audio files are allowed"):
        super().__init__(message, status_code=415)

class DirectoryCreationForbiddenException(MornyeException):
    """Attempted to create a directory or subdirectory in storage."""
    def __init__(self, message: str = "Storage is strictly flat: directories or subdirectories are forbidden"):
        super().__init__(message, status_code=403)

class FileNotFoundStorageException(MornyeException):
    """Requested audio file was not found in storage."""
    def __init__(self, message: str = "Requested audio file not found"):
        super().__init__(message, status_code=404)

class DuplicateFileException(MornyeException):
    """Audio file already exists."""
    def __init__(self, message: str = "A file with this name already exists in storage"):
        super().__init__(message, status_code=409)

class AuthenticationException(MornyeException):
    """Invalid credentials or missing authentication."""
    def __init__(self, message: str = "Authentication required or invalid credentials"):
        super().__init__(message, status_code=401)

class PermissionDeniedException(MornyeException):
    """Authenticated user does not have permission for this action."""
    def __init__(self, message: str = "Permission denied"):
        super().__init__(message, status_code=403)

class UserAlreadyExistsException(MornyeException):
    """User with username already exists."""
    def __init__(self, message: str = "User already exists"):
        super().__init__(message, status_code=409)

# Aliases for compatibility
StorageQuotaExceededException = QuotaExceededException
InvalidAudioFileException = NonAudioFileException
AuthenticationFailedException = AuthenticationException
ResourceNotFoundException = FileNotFoundStorageException
ConflictException = DuplicateFileException
