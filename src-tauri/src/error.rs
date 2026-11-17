//! Error type shared by all backend modules and serialized to the frontend.

use serde::Serialize;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    /// A user-facing message that is safe to display.
    #[error("{0}")]
    Message(String),
    /// Input/state validation failure.
    #[error("{0}")]
    Validation(String),
    /// Running project code requires explicit consent.
    #[error("{0}")]
    ConsentRequired(String),
    /// A requested entity does not exist.
    #[error("{0}")]
    NotFound(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("serialization error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("execution error: {0}")]
    Execution(String),
}

impl AppError {
    pub fn message(text: impl Into<String>) -> Self {
        Self::Message(text.into())
    }

    pub fn validation(text: impl Into<String>) -> Self {
        Self::Validation(text.into())
    }

    pub fn not_found(text: impl Into<String>) -> Self {
        Self::NotFound(text.into())
    }

    pub fn execution(text: impl Into<String>) -> Self {
        Self::Execution(text.into())
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Self::Message(_) => "error",
            Self::Validation(_) => "validation",
            Self::ConsentRequired(_) => "consent_required",
            Self::NotFound(_) => "not_found",
            Self::Io(_) => "io",
            Self::Db(_) => "database",
            Self::Json(_) => "serialization",
            Self::Execution(_) => "execution",
        }
    }
}

impl Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct;
        let mut state = serializer.serialize_struct("AppError", 2)?;
        state.serialize_field("kind", self.kind())?;
        state.serialize_field("message", &self.to_string())?;
        state.end()
    }
}

pub type AppResult<T> = Result<T, AppError>;
