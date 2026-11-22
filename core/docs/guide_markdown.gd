extends RefCounted
## Turns the user guide's Markdown into sections of RichTextLabel BBCode, for
## the in-app guide. Handles what the guide uses: headings (# title, ##
## sections, ### subsections), paragraphs, bullet and numbered lists (nested
## by indent), **bold**, `code` and [links](url). Web links stay clickable;
## links to other files become plain text.

const SECTION_SIZE := 20
const SUBSECTION_SIZE := 16


## {"title", "sections": [{"title", "bbcode", "text", "subsections": [{"title", "paragraph"}]}]}.
## `text` is the section's plain text, for searching; `paragraph` is where a
## subsection starts in the section's BBCode (for scroll_to_paragraph).
static func parse(markdown: String, code_color := Color("9bd7ff")) -> Dictionary:
	var result := {"title": "", "sections": []}
	var section: Dictionary = {}
	var block: Array = []
	for raw in markdown.replace("\r", "").split("\n"):
		var line: String = raw
		if line.begins_with("# "):
			result.title = line.substr(2).strip_edges()
			continue
		if line.begins_with("## "):
			_flush(section, block, code_color)
			section = {"title": line.substr(3).strip_edges(), "parts": [], "subsections": [], "text": ""}
			result.sections.append(section)
			section.parts.append("[font_size=%d][b]%s[/b][/font_size]" % [SECTION_SIZE, inline(section.title, code_color)])
			continue
		if section.is_empty():
			# Text before the first section: an introduction.
			section = {"title": "Introduction", "parts": [], "subsections": [], "text": ""}
			result.sections.append(section)
		if line.begins_with("### "):
			_flush(section, block, code_color)
			var title := line.substr(4).strip_edges()
			section.subsections.append({"title": title, "paragraph": section.parts.size()})
			section.parts.append("[font_size=%d][b]%s[/b][/font_size]" % [SUBSECTION_SIZE, inline(title, code_color)])
			continue
		if line.strip_edges().is_empty():
			_flush(section, block, code_color)
			continue
		block.append(line)
	_flush(section, block, code_color)
	for entry in result.sections:
		entry.bbcode = "\n".join(entry.parts)
		entry.text = (entry.title + "\n" + entry.text).to_lower()
		entry.erase("parts")
	return result


## A block of lines: list items (with their continuation lines) or a paragraph.
static func _flush(section: Dictionary, block: Array, code_color: Color) -> void:
	if block.is_empty() or section.is_empty():
		block.clear()
		return
	var items := RegEx.create_from_string("^(\\s*)(- |\\d+\\. )(.*)$")
	var entries: Array = []
	for line in block:
		var match := items.search(line)
		if match != null:
			entries.append({"depth": match.get_string(1).length() / 2, "marker": match.get_string(2).strip_edges(), "text": match.get_string(3).strip_edges()})
		elif not entries.is_empty():
			entries[-1].text += " " + line.strip_edges()
		else:
			entries.append({"depth": -1, "marker": "", "text": line.strip_edges()})
	# A paragraph's lines join into one; list items stay separate.
	var paragraph: Array = []
	for entry in entries:
		section.text += entry.text + "\n"
		if entry.depth < 0:
			paragraph.append(entry.text)
			continue
		if not paragraph.is_empty():
			section.parts.append(inline(" ".join(paragraph), code_color))
			paragraph.clear()
		var bullet: String = "•" if entry.marker == "-" else entry.marker
		var depth: int = mini(entry.depth, 3) + 1
		section.parts.append("[indent]".repeat(depth) + bullet + " " + inline(entry.text, code_color) + "[/indent]".repeat(depth))
	if not paragraph.is_empty():
		section.parts.append(inline(" ".join(paragraph), code_color))
	block.clear()


## Inline Markdown to BBCode: square brackets are escaped, then links, bold
## and code are converted.
static func inline(text: String, code_color := Color("9bd7ff")) -> String:
	var open := char(1)
	var close := char(2)
	var result := text.replace("[", open).replace("]", close)
	var link := RegEx.create_from_string(open + "([^" + close + "]+)" + close + "\\(([^)]+)\\)")
	var found := link.search(result)
	while found != null:
		var label := found.get_string(1)
		var url := found.get_string(2)
		var replacement := "[url=%s]%s[/url]" % [url, label] if url.begins_with("http") else label
		result = result.substr(0, found.get_start()) + replacement + result.substr(found.get_end())
		found = link.search(result, found.get_start() + replacement.length())
	result = RegEx.create_from_string("\\*\\*(.+?)\\*\\*").sub(result, "[b]$1[/b]", true)
	result = RegEx.create_from_string("`([^`]+)`").sub(result, "[color=#%s][code]$1[/code][/color]" % code_color.to_html(false), true)
	return result.replace(open, "[lb]").replace(close, "[rb]")
