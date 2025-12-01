#!/bin/bash
#
# Remove or rename sources/layers from Fontra font projects.
#
# Usage:
#   ./remove_sources.sh <font.fontra> [--keep ID] [source_id1] [source_id2] ...
#
# Examples:
#   # Remove default Thin and Black sources, keep Regular
#   ./remove_sources.sh MyFont.fontra
#
#   # Remove specific source IDs, keep a specific one
#   ./remove_sources.sh MyFont.fontra --keep f98ae03e 70fdd226 cf36384c
#
#   # Process multiple fonts
#   ./remove_sources.sh Font1.fontra Font2.fontra
#
# Default source IDs removed (if none specified):
#   70fdd226 (Black)
#   cf36384c (Thin)
#
# Default source ID to keep:
#   f98ae03e (Regular)
#
# What this script does:
#   1. Removes source entries from font-data.json
#   2. For each glyph:
#      - If glyph has the "keep" layer: removes other layers, updates references
#      - If glyph ONLY has "remove" layers: renames them to "keep" ID
#      - Updates all locationBase references to point to "keep" ID

# Default source IDs to remove
DEFAULT_REMOVE_IDS=("70fdd226" "cf36384c")
# Default source ID to keep (for updating locationBase references)
DEFAULT_KEEP_ID="f98ae03e"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <font.fontra> [--keep ID] [source_id1] [source_id2] ..."
    echo ""
    echo "Remove sources/layers from Fontra font projects."
    echo ""
    echo "Arguments:"
    echo "  font.fontra    Path to .fontra directory"
    echo "  --keep ID      Source ID to keep (references will be updated to this)"
    echo "  source_ids     Source IDs to remove (default: 70fdd226 cf36384c)"
    echo ""
    echo "Examples:"
    echo "  $0 MyFont.fontra"
    echo "  $0 MyFont.fontra --keep f98ae03e 70fdd226 cf36384c"
    exit 1
}

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Install with: sudo apt install jq"
    exit 1
fi

# Parse arguments
FONTS=()
REMOVE_IDS=()
KEEP_ID="$DEFAULT_KEEP_ID"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep|-k)
            KEEP_ID="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [[ -d "$1" ]] || [[ "$1" == *.fontra ]]; then
                FONTS+=("$1")
            else
                REMOVE_IDS+=("$1")
            fi
            shift
            ;;
    esac
done

# Check for font argument
if [[ ${#FONTS[@]} -eq 0 ]]; then
    usage
fi

# Use default IDs if none specified
if [[ ${#REMOVE_IDS[@]} -eq 0 ]]; then
    REMOVE_IDS=("${DEFAULT_REMOVE_IDS[@]}")
fi

# Process a single glyph file
# Returns 0 if modified, 1 if not modified
process_glyph() {
    local glyph_file="$1"
    local tmp_file
    tmp_file=$(mktemp)
    local original_content
    original_content=$(cat "$glyph_file")
    
    # Check if glyph has the keep layer
    local has_keep_layer
    has_keep_layer=$(jq -r ".layers.\"$KEEP_ID\" != null" "$glyph_file")
    
    # Build jq filter based on what layers exist
    local jq_filter=""
    
    if [[ "$has_keep_layer" == "true" ]]; then
        # Glyph has the keep layer - remove other layers and update references
        
        # Filter sources array - remove entries where layerName is in remove list
        jq_filter='.sources = [.sources[] | select('
        local first=true
        for remove_id in "${REMOVE_IDS[@]}"; do
            if [[ "$first" == true ]]; then
                first=false
            else
                jq_filter+=' and '
            fi
            jq_filter+=".layerName != \"$remove_id\""
        done
        jq_filter+=')]'
        
        # Update locationBase references in remaining sources
        for remove_id in "${REMOVE_IDS[@]}"; do
            jq_filter+=" | .sources = [.sources[] | if .locationBase == \"$remove_id\" then .locationBase = \"$KEEP_ID\" else . end]"
        done
        
        # Remove layers
        for remove_id in "${REMOVE_IDS[@]}"; do
            jq_filter+=" | del(.layers.\"$remove_id\")"
        done
    else
        # Glyph only has remove layers - rename first one to keep ID
        # Find which remove ID this glyph uses
        local found_id=""
        for remove_id in "${REMOVE_IDS[@]}"; do
            local has_layer
            has_layer=$(jq -r ".layers.\"$remove_id\" != null" "$glyph_file")
            if [[ "$has_layer" == "true" ]]; then
                found_id="$remove_id"
                break
            fi
        done
        
        if [[ -z "$found_id" ]]; then
            # No matching layers found, skip
            rm -f "$tmp_file"
            return 1
        fi
        
        # Rename the layer and update all references
        jq_filter=".layers.\"$KEEP_ID\" = .layers.\"$found_id\" | del(.layers.\"$found_id\")"
        
        # Update sources array - rename layerName and locationBase
        jq_filter+=" | .sources = [.sources[] | "
        jq_filter+="if .layerName == \"$found_id\" then .layerName = \"$KEEP_ID\" else . end | "
        jq_filter+="if .locationBase == \"$found_id\" then .locationBase = \"$KEEP_ID\" else . end"
        jq_filter+="]"
        
        # Remove any other remove IDs
        for remove_id in "${REMOVE_IDS[@]}"; do
            if [[ "$remove_id" != "$found_id" ]]; then
                jq_filter+=" | del(.layers.\"$remove_id\")"
                jq_filter+=" | .sources = [.sources[] | select(.layerName != \"$remove_id\")]"
            fi
        done
    fi
    
    # Apply filter and output compact JSON
    if jq -c "$jq_filter" "$glyph_file" > "$tmp_file" 2>/dev/null; then
        local new_content
        new_content=$(cat "$tmp_file")
        # Check if file actually changed
        if [[ "$original_content" != "$new_content" ]]; then
            mv "$tmp_file" "$glyph_file"
            return 0  # Modified
        fi
    fi
    rm -f "$tmp_file"
    return 1  # Not modified
}

# Process font-data.json
process_font_data() {
    local font_data="$1"
    local tmp_file
    tmp_file=$(mktemp)
    
    # Build jq filter to remove sources
    local jq_filter=""
    for remove_id in "${REMOVE_IDS[@]}"; do
        if [[ -n "$jq_filter" ]]; then
            jq_filter+=" | "
        fi
        jq_filter+="del(.sources.\"$remove_id\")"
    done
    
    if jq "$jq_filter" "$font_data" > "$tmp_file"; then
        mv "$tmp_file" "$font_data"
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# Process a font
process_font() {
    local font_path="$1"
    
    echo -e "\n${GREEN}Processing: ${font_path}${NC}"
    
    # Validate font directory
    if [[ ! -d "$font_path" ]]; then
        echo -e "${RED}Error: Not a directory: ${font_path}${NC}"
        return 1
    fi
    
    local font_data="${font_path}/font-data.json"
    local glyphs_dir="${font_path}/glyphs"
    
    if [[ ! -f "$font_data" ]]; then
        echo -e "${RED}Error: No font-data.json found${NC}"
        return 1
    fi
    
    # Show current sources
    echo -e "${YELLOW}Current sources:${NC}"
    jq -r '.sources | to_entries[] | "  \(.key): \(.value.name)"' "$font_data"
    
    echo -e "${YELLOW}Removing:${NC} ${REMOVE_IDS[*]}"
    echo -e "${YELLOW}Keeping/Renaming to:${NC} ${KEEP_ID}"
    
    # Process font-data.json
    if process_font_data "$font_data"; then
        echo -e "  ${GREEN}✓${NC} Updated font-data.json"
    else
        echo -e "  ${RED}✗${NC} Failed to update font-data.json"
        return 1
    fi
    
    # Process all glyph files
    if [[ -d "$glyphs_dir" ]]; then
        local total=0
        local updated=0
        local renamed=0
        
        echo -e "${YELLOW}Processing glyphs...${NC}"
        
        # Use find to handle special characters in filenames
        while IFS= read -r -d '' glyph_file; do
            ((total++)) || true
            
            # Check if this will be a rename operation
            local has_keep
            has_keep=$(jq -r ".layers.\"$KEEP_ID\" != null" "$glyph_file")
            
            if process_glyph "$glyph_file"; then
                ((updated++)) || true
                if [[ "$has_keep" == "false" ]]; then
                    ((renamed++)) || true
                    echo -e "  ${BLUE}↻${NC} $(basename "$glyph_file") (renamed)"
                else
                    echo -e "  ${GREEN}✓${NC} $(basename "$glyph_file")"
                fi
            fi
        done < <(find "$glyphs_dir" -maxdepth 1 -name "*.json" -print0)
        
        echo -e "\n  ${GREEN}Summary:${NC} Updated ${updated}/${total} glyph files (${renamed} renamed)"
    else
        echo -e "  ${YELLOW}!${NC} No glyphs directory found"
    fi
    
    echo -e "${GREEN}Done!${NC}"
}

# Main
echo "Fontra Source Remover"
echo "====================="
echo "Sources to remove: ${REMOVE_IDS[*]}"
echo "Keep/rename to: ${KEEP_ID}"

for font in "${FONTS[@]}"; do
    process_font "$font"
done
