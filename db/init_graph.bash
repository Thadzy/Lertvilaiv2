#!/bin/bash
# Merge SQL files in dependency order: types → tables → indexes → functions → triggers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/graph.sql"

# List of files in execution order
FILES=(
  "graph/types.sql"
  "graph/tables.sql"
  "graph/indexes.sql"
  "graph/triggers.sql"
  "graph/views.sql"
  "graph/functions.sql"
  "graph/permissions.sql"
)

# Remove existing merged file
rm -f "$OUTPUT_FILE"

echo "Merging SQL files into graph.sql..."

# Merge files
for file in "${FILES[@]}"; do
  filepath="$SCRIPT_DIR/$file"

  if [ ! -f "$filepath" ]; then
    echo "Warning: $file not found, skipping..."
    continue
  fi

  echo "Adding $file..."

  # Add separator comment
  echo "" >> "$OUTPUT_FILE"
  echo "-- ============================================================================" >> "$OUTPUT_FILE"
  echo "-- $file" >> "$OUTPUT_FILE"
  echo "-- ============================================================================" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  # Strip BEGIN/COMMIT from individual files and append content
  sed '/^BEGIN;$/d; /^COMMIT;$/d' "$filepath" >> "$OUTPUT_FILE"
done

# Wrap entire file in single transaction
echo "Wrapping in transaction..."
{
  echo "BEGIN;"
  echo ""
  cat "$OUTPUT_FILE"
  echo ""
  echo "COMMIT;"
} > "$OUTPUT_FILE.tmp"

mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

echo "✓ Successfully created graph.sql"
echo "  Location: $OUTPUT_FILE"
