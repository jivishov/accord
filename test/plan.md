# Implementation Plan: User Input Sanitizer

## Overview

Create a Python module that sanitizes user input by removing known dangerous patterns.
This provides defense-in-depth against injection attacks but is NOT sufficient as a
standalone defense - always use parameterized queries for SQL and proper escaping
libraries for other contexts.

## Requirements

### Functional Requirements

1. **SQL Sanitization Function**
   - Function: `sanitize_sql(value: str) -> str`
   - Remove dangerous SQL characters and keywords as defense-in-depth
   - Handle: `'`, `"`, `;`, `--`, `/*`, `*/`, `UNION`, `SELECT`, `DROP`, `DELETE`
   - **Note**: This is defense-in-depth only. Always use parameterized queries as the primary defense against SQL injection.

2. **HTML Sanitization Function**
   - Function: `sanitize_html(value: str) -> str`
   - Escape HTML special characters: `<`, `>`, `&`, `"`, `'`
   - Prevent XSS attacks
   - Return string safe for HTML display

3. **General Sanitizer**
   - Function: `sanitize(value: str, context: Literal["sql", "html", "both"]) -> str`
   - Apply appropriate sanitization based on context
   - "both" applies SQL first, then HTML

4. **Batch Processing**
   - Function: `sanitize_batch(values: list[str], context: Literal["sql", "html", "both"]) -> list[str]`
   - Process multiple values efficiently
   - Preserve order

### Non-Functional Requirements

- All functions must have type hints
- All functions must have docstrings with examples
- Handle None and empty string inputs gracefully
- No external dependencies (stdlib only)

## File Structure

```
sanitizer/
├── __init__.py      # Export public functions
├── sanitizer.py     # Main implementation
└── constants.py     # SQL keywords and HTML entities
```

## API Examples

```python
from sanitizer import sanitize, sanitize_sql, sanitize_html, sanitize_batch

# SQL sanitization (removes dangerous chars and keywords including DROP)
sanitize_sql("'; DROP TABLE users; --")
# Returns: "  TABLE users "

# HTML sanitization (escapes all special chars including quotes)
sanitize_html("<script>alert('xss')</script>")
# Returns: "&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;"

# Combined
sanitize("'; <script>", context="both")
# Returns: " &lt;script&gt;"

# Batch (HTML escapes quotes to &#x27;)
sanitize_batch(["<b>", "'; --"], context="html")
# Returns: ["&lt;b&gt;", "&#x27;; --"]
```

## Implementation Notes

- Use `html.escape()` from stdlib for HTML encoding
- Use regex for SQL pattern matching
- SQL keywords should be case-insensitive
- Preserve non-dangerous characters unchanged
