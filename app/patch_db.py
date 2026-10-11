import re

with open("rust/src/cloud/db.rs", "r") as f:
    content = f.read()

# Add a mark_tags_attempted function
content = content.replace(
    "pub fn clear(&self) -> Result<()> {",
    """pub fn mark_tags_attempted(&self, file_id: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE tracks SET tags_read = 1 WHERE file_id = ?",
            [file_id],
        )?;
        Ok(())
    }

    pub fn clear(&self) -> Result<()> {"""
)

with open("rust/src/cloud/db.rs", "w") as f:
    f.write(content)
