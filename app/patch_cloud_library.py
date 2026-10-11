import re

with open("rust/src/api/cloud_library.rs", "r") as f:
    content = f.read()

replacement = """            // Not a FLAC file, or a damaged header. The row keeps the name it
            // was indexed under rather than disappearing from the library.
            Err(_) => {
                let _ = with_db(|db| {
                    db.mark_tags_attempted(&file_id)?;
                    Ok(())
                });
                return Ok(false);
            }
        }
    }

    let _ = with_db(|db| {
        db.mark_tags_attempted(&file_id)?;
        Ok(())
    });
    Ok(false)"""

content = content.replace(
"""            // Not a FLAC file, or a damaged header. The row keeps the name it
            // was indexed under rather than disappearing from the library.
            Err(_) => return Ok(false),
        }
    }

    Ok(false)""", replacement)

with open("rust/src/api/cloud_library.rs", "w") as f:
    f.write(content)
