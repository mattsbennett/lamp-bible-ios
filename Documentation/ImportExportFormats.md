# Import/Export Formats for Notes and Devotionals

This document describes the markdown-based import/export formats for user notes and devotionals in Lamp Bible. Both formats support embedded media (images and audio) via a shared `media/` folder structure.

## Table of Contents

- [Directory Structure](#directory-structure)
- [Notes Format](#notes-format)
- [Devotionals Format](#devotionals-format)
- [Media Files](#media-files)
- [Import Process](#import-process)
- [Export Process](#export-process)
- [Examples](#examples)

---

## Directory Structure

Import and export use the iCloud Documents container:

```
iCloud Drive/Lamp Bible/
├── Import/
│   ├── Notes/
│   │   ├── Matthew.md
│   │   ├── Romans.md
│   │   └── media/
│   │       ├── image-abc123.jpg
│   │       └── audio-def456.m4a
│   └── Devotionals/
│       ├── my-devotional.md
│       └── media/
│           ├── header-image.jpg
│           └── meditation-audio.m4a
└── Export/
    ├── Notes/
    │   ├── Genesis.md
    │   ├── Matthew.md
    │   ├── All_Notes.md
    │   └── media/
    │       └── ...
    └── Devotionals/
        ├── walking-by-faith.md
        ├── All_Devotionals.md
        └── media/
            └── ...
```

---

## Notes Format

Notes use a structured markdown format with YAML frontmatter. Each file can contain notes for a single book or multiple books.

### Single-Book Format

```markdown
---
id: notes
type: notes
name: "My Notes"
author: "John Smith"
book: Matthew
bookNumber: 40
---

# Matthew

## Chapter 1

### Introduction

This chapter begins with the genealogy of Jesus Christ...

### 1:1

The book of the genealogy of Jesus Christ means...[^1]

### 1:2-3

Abraham was called by God...[^2]

## Chapter 2

### Introduction

Chapter 2 focuses on the visit of the Magi...

### 2:1

Bethlehem was a small town about 5 miles south of Jerusalem.

---

[^1:1-1]: This is a footnote for verse 1:1.

[^1:2-2]: Another footnote for verses 2-3.
```

### Multi-Book Format

When exporting all notes to a single file (`All_Notes.md`):

```markdown
# My Notes

---

## Genesis

### Chapter 1

#### Introduction

In the beginning, God created...

#### 1:1

"In the beginning" establishes God's eternality...[^Gen-1:1-1]

## Matthew

### Chapter 1

#### 1:1

The genealogy connects Jesus to Abraham and David...[^Matt-1:1-1]

---

[^Gen-1:1-1]: Hebrew "reshith" means first, beginning, or chief.

[^Matt-1:1-1]: "Son of David" emphasizes Jesus' royal lineage.
```

### Notes Structure

| Level | Markdown | Description |
|-------|----------|-------------|
| H1 (`#`) | Book title | Book name (single-book) or "My Notes" (multi-book) |
| H2 (`##`) | Book name | Only in multi-book format |
| H3 (`###`) | Chapter N | Chapter header (single-book) |
| H4 (`####`) | Introduction or verse ref | Section header (multi-book) |

### Verse References

Verse references follow the pattern `chapter:verse` or `chapter:start-end`:

- `1:1` - Single verse
- `1:2-5` - Verse range in same chapter
- `1:28-2:3` - Cross-chapter range

### Footnotes

Footnotes use standard markdown format with unique IDs:

- In-text marker: `[^1]` or `[^Gen-1:1-1]`
- Definition at end: `[^Gen-1:1-1]: Footnote content here.`

Multi-line footnotes use 4-space indentation:

```markdown
[^Gen-1:1-1]: This is a longer footnote that
    spans multiple lines with proper
    indentation.
```

---

## Devotionals Format

Devotionals use YAML frontmatter with rich content blocks.

### Basic Structure

```markdown
---
id: "uuid-string"
title: "Walking by Faith"
subtitle: "A morning reflection"
author: "John Smith"
date: "2025-01-18"
tags: ["faith", "prayer", "morning"]
category: "devotional"
series:
  id: "series-uuid"
  name: "Faith Series"
  order: 1
keyScriptures:
  - ref: "Hebrews 11:1"
    sv: 58011001
  - ref: "2 Corinthians 5:7"
    sv: 47005007
---

## Summary

A brief overview of walking by faith in daily life.

## Content

### Introduction

Faith is the substance of things hoped for...

> "Now faith is the substance of things hoped for, the evidence of things not seen."
> — Hebrews 11:1

### Walking Daily

Living by faith means trusting God even when...

![A path through the forest](media/forest-path.jpg)

1. Trust in God's promises
2. Step forward even in uncertainty
3. Remember His faithfulness

### Meditation

Take time to listen to this reflection:

[Morning meditation audio](media/meditation.m4a)

### Conclusion

As we walk by faith today...

---

[^1]: Additional note or reference.
```

### Frontmatter Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique identifier (UUID) |
| `title` | Yes | Devotional title |
| `subtitle` | No | Optional subtitle |
| `author` | No | Author name |
| `date` | No | ISO 8601 date (YYYY-MM-DD) |
| `tags` | No | Array of tags |
| `category` | No | One of: devotional, sermon, reflection, study, prayer, testimony, other |
| `series.id` | No | Series UUID |
| `series.name` | No | Series display name |
| `series.order` | No | Order within series |
| `keyScriptures` | No | Array of scripture references |

### Content Blocks

| Block | Syntax | Description |
|-------|--------|-------------|
| Paragraph | Plain text | Regular text content |
| Heading | `##`, `###`, etc. | Section headings |
| Blockquote | `> text` | Scripture quotes or emphasis |
| Bullet list | `- item` | Unordered list |
| Numbered list | `1. item` | Ordered list |
| Image | `![caption](media/file.jpg)` | Embedded image |
| Audio | `[caption](media/file.m4a)` | Embedded audio |

### All Devotionals Export

When exporting all devotionals to `All_Devotionals.md`:

```markdown
# My Devotionals

---

## Walking by Faith

**Date:** 2025-01-18 | **Category:** devotional | **Tags:** faith, prayer

### Summary

Brief summary here.

### Content

Content blocks here...

---

## Another Devotional

...
```

---

## Media Files

Media files are stored in a `media/` folder alongside the markdown files.

### Supported Formats

**Images:**
- JPEG (.jpg, .jpeg)
- PNG (.png)
- GIF (.gif)
- WebP (.webp)
- HEIC (.heic)

**Audio:**
- M4A (.m4a) - Recommended
- MP3 (.mp3)
- WAV (.wav)
- AAC (.aac)
- OGG (.ogg)

### File Naming

Media files use UUID-based filenames to avoid conflicts:

```
media/
├── abc12345-image.jpg
├── def67890-audio.m4a
└── ...
```

When exporting, the app copies media files and updates references in the markdown.

### Image Syntax

```markdown
![Alt text / Caption](media/filename.jpg)
```

Example:
```markdown
![A beautiful sunrise over the mountains](media/sunrise-abc123.jpg)
```

### Audio Syntax

Audio uses standard link syntax (not image syntax):

```markdown
[Caption text](media/filename.m4a)
```

Example:
```markdown
[Listen to today's meditation](media/meditation-def456.m4a)
```

---

## Import Process

### Notes Import

1. Place `.md` files in `Import/Notes/`
2. Place any media files in `Import/Notes/media/`
3. Open the app - import happens automatically on sync
4. Successfully imported files are deleted from the import folder

**Import behavior:**
- Single-book files create/update notes for that book
- Multi-book files (`# My Notes` header) import notes for all included books
- Existing notes are merged by verse reference
- Footnotes are renumbered to sequential IDs (1, 2, 3...)

### Devotionals Import

1. Place `.md` files in `Import/Devotionals/`
2. Place any media files in `Import/Devotionals/media/`
3. Open the app - import happens automatically on sync
4. Successfully imported files are deleted

**Import behavior:**
- Each file creates one devotional entry
- New UUIDs are generated for imported devotionals
- Media files are copied to local storage
- Timestamps are updated to import time

### Error Handling

- Invalid book names: Import fails with error
- Missing frontmatter fields: Uses defaults where possible
- Missing media files: Content imports, missing media references preserved
- Parse errors: File is not deleted, error logged

---

## Export Process

### Notes Export

**Export single book:**
- Go to Notes → select book → Export
- Creates `Export/Notes/{BookName}.md`
- Media copied to `Export/Notes/media/`

**Export all notes:**
- Go to Settings → Export → Notes → Export All
- Creates individual files per book, plus `All_Notes.md`
- All media consolidated in `Export/Notes/media/`

### Devotionals Export

**Export single devotional:**
- Open devotional → Share → Export to Markdown
- Creates `Export/Devotionals/{title}.md`
- Media copied to `Export/Devotionals/media/`

**Export all devotionals:**
- Go to Settings → Export → Devotionals → Export All
- Creates individual files per devotional, plus `All_Devotionals.md`
- All media consolidated in `Export/Devotionals/media/`

### Footnote ID Transformation

During export, local footnote IDs are transformed to unique IDs:

| Context | Local ID | Exported ID |
|---------|----------|-------------|
| Notes (single book) | `[^1]` | `[^1:5-1]` (chapter:verse-number) |
| Notes (all books) | `[^1]` | `[^Gen-1:5-1]` (book-chapter:verse-number) |
| Devotionals | `[^1]` | `[^1]` (unchanged) |

---

## Examples

### Complete Notes Example

```markdown
---
id: notes
type: notes
name: "My Study Notes"
author: "Jane Doe"
book: John
bookNumber: 43
---

# John

## Chapter 1

### Introduction

The Gospel of John opens with one of the most profound theological statements in Scripture...

![Ancient scroll](media/scroll-image.jpg)

### 1:1

"In the beginning was the Word" (Greek: *Logos*)[^1] echoes Genesis 1:1 and establishes Christ's eternality.

The term *Logos* carried rich philosophical meaning in the ancient world.

### 1:14

"The Word became flesh" - This is the incarnation[^2]. God took on human nature without ceasing to be God.

[Listen to commentary on the incarnation](media/incarnation-commentary.m4a)

---

[^1:1-1]: Greek λόγος (logos) - word, reason, plan. Used by Greek philosophers to describe the rational principle governing the cosmos.

[^1:14-1]: The Incarnation is the central mystery of the Christian faith - God becoming man while remaining fully God.
```

### Complete Devotional Example

```markdown
---
id: "d4f8a2b1-3c5e-4d7f-9a8b-6c1e2f3d4a5b"
title: "Finding Peace in the Storm"
subtitle: "When life feels overwhelming"
author: "Pastor Michael"
date: "2025-01-15"
tags: ["peace", "trust", "anxiety", "storms"]
category: "devotional"
keyScriptures:
  - ref: "Mark 4:39"
    sv: 41004039
  - ref: "Isaiah 26:3"
    sv: 23026003
---

## Summary

When storms rage in our lives, we can find peace by trusting in the One who commands the wind and waves.

## Content

### The Storm

![Stormy sea](media/storm-sea.jpg)

Life often brings unexpected storms. Health crises, job loss, relationship struggles, financial pressure - these can feel like waves threatening to overwhelm us.

### Jesus in the Boat

The disciples faced a terrifying storm on the Sea of Galilee. Jesus was with them, yet asleep in the boat.

> "And he arose, and rebuked the wind, and said unto the sea, Peace, be still. And the wind ceased, and there was a great calm."
> — Mark 4:39

### Finding Peace

Three keys to peace in the storm:

1. **Remember His presence** - Jesus is in your boat
2. **Trust His power** - He commands the wind and waves
3. **Rest in His love** - Perfect love casts out fear

[Morning meditation: Peace in the Storm](media/peace-meditation.m4a)

### Prayer

Lord, help me to trust You in the midst of my storms. Give me Your peace that surpasses understanding. Amen.

---

[^1]: The Sea of Galilee is known for sudden, violent storms due to its location below sea level surrounded by hills.
```

---

## Troubleshooting

### Import Issues

**"Unknown book" error:**
- Ensure the book name in frontmatter matches standard book names
- Check spelling: "1 Samuel" not "1st Samuel"

**Media not importing:**
- Verify files are in the correct `media/` subfolder
- Check file extensions match supported formats
- Ensure filenames match references in markdown exactly

**Footnotes not appearing:**
- Ensure footnote markers `[^n]` have matching definitions `[^n]:`
- Check for correct indentation on multi-line footnotes

### Export Issues

**Missing media in export:**
- Media files must exist in local storage
- Check that media references in content use correct IDs

**Footnotes duplicated:**
- This can happen when re-exporting. Each export generates new unique IDs.

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-01-09 | Initial notes import/export |
| 1.1 | 2025-01-19 | Added media support for images and audio |
| 1.1 | 2025-01-19 | Added devotionals import/export |
