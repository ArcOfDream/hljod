package kdl

import "core:unicode"
import "core:unicode/utf8"

Token_Type :: enum {
	Invalid,
	EOF,
	Identifier,
	String,
	Number,
	Boolean,
	Null,
	Equals,
	OpenBrace,
	CloseBrace,
	Semicolon,
	LineComment,
	Slashdash,
}

Token :: struct {
	type: Token_Type,
	text: string,
	line: int,
	col:  int,
}

Lexer :: struct {
	source: string,
	pos:    int,
	line:   int,
	col:    int,
}

lexer_init :: proc(l: ^Lexer, source: string) {
	l.source = source
	l.pos = 0
	l.line = 1
	l.col = 1
}

lexer_next :: proc(l: ^Lexer) -> Token {
	for l.pos < len(l.source) {
		r, width := utf8.decode_rune_in_string(l.source[l.pos:])
		if r == utf8.RUNE_ERROR && width == 1 {
			tok := Token {
				type = .Invalid,
				text = l.source[l.pos:l.pos + 1],
				line = l.line,
				col  = l.col,
			}
			l.pos += 1
			l.col += 1
			return tok
		}

		// newline
		if r == '\n' {
			tok := Token {
				type = .Semicolon,
				text = "\n",
				line = l.line,
				col  = l.col,
			}
			l.pos += 1
			l.line += 1
			l.col = 1
			return tok
		}

		// whitespace - KDL also allows commas as separators
		if r == ' ' || r == '\t' || r == '\r' || r == ',' {
			l.pos += width
			l.col += 1
			continue
		}

		// line continuation - \ at end of line joins next line
		if r == '\\' && l.pos + 1 < len(l.source) {
			next_r, _ := utf8.decode_rune_in_string(l.source[l.pos + 1:])
			if next_r == '\n' {
				l.pos += 2
				l.line += 1
				l.col = 1
				continue
			}
		}

		// comments and slashdash
		if r == '/' && l.pos + 1 < len(l.source) {
			next_byte := l.source[l.pos + 1]
			if next_byte == '/' {
				start_col := l.col
				start := l.pos
				l.pos += 2
				for l.pos < len(l.source) && l.source[l.pos] != '\n' {
					l.pos += 1
				}
				return Token {
					type = .LineComment,
					text = l.source[start:l.pos],
					line = l.line,
					col = start_col,
				}
			}
			if next_byte == '*' {
				l.pos += 2
				l.col += 2
				depth := 1
				for depth > 0 && l.pos < len(l.source) {
					curr_r, w := utf8.decode_rune_in_string(l.source[l.pos:])
					if curr_r == '\n' {
						l.line += 1
						l.col = 1
						l.pos += 1
					} else if curr_r == '/' &&
					   l.pos + 1 < len(l.source) &&
					   l.source[l.pos + 1] == '*' {
						depth += 1
						l.pos += 2
						l.col += 2
					} else if curr_r == '*' &&
					   l.pos + 1 < len(l.source) &&
					   l.source[l.pos + 1] == '/' {
						depth -= 1
						l.pos += 2
						l.col += 2
					} else {
						l.pos += w
						l.col += 1
					}
				}
				continue
			}
			if next_byte == '-' {
				tok := Token {
					type = .Slashdash,
					text = "/-",
					line = l.line,
					col  = l.col,
				}
				l.pos += 2
				l.col += 2
				return tok
			}
		}

		if r == ';' {
			tok := Token {
				type = .Semicolon,
				text = ";",
				line = l.line,
				col  = l.col,
			}
			l.pos += 1
			l.col += 1
			return tok
		}
		if r == '=' {
			tok := Token {
				type = .Equals,
				text = "=",
				line = l.line,
				col  = l.col,
			}
			l.pos += 1
			l.col += 1
			return tok
		}
		if r == '{' {
			tok := Token {
				type = .OpenBrace,
				text = "{",
				line = l.line,
				col  = l.col,
			}
			l.pos += 1
			l.col += 1
			return tok
		}
		if r == '}' {
			tok := Token {
				type = .CloseBrace,
				text = "}",
				line = l.line,
				col  = l.col,
			}
			l.pos += 1
			l.col += 1
			return tok
		}

		// string literal
		if r == '"' {
			return lex_string(l)
		}

		// bare word - identifier, number, boolean, null
		if is_bare_start(r) {
			return lex_bare(l)
		}

		// invalid character
		tok := Token {
			type = .Invalid,
			text = l.source[l.pos:l.pos + width],
			line = l.line,
			col  = l.col,
		}
		l.pos += width
		l.col += 1
		return tok
	}

	return Token{type = .EOF, line = l.line, col = l.col}
}

lex_string :: proc(l: ^Lexer) -> Token {
	start := l.pos
	line := l.line
	col := l.col
	l.pos += 1
	l.col += 1

	for l.pos < len(l.source) {
		c := l.source[l.pos]
		if c == '"' {
			l.pos += 1
			l.col += 1
			return Token{type = .String, text = l.source[start:l.pos], line = line, col = col}
		}
		if c == '\n' {
			return Token{type = .String, text = l.source[start:l.pos], line = line, col = col}
		}
		if c == '\\' && l.pos + 1 < len(l.source) {
			l.pos += 2
			l.col += 2
		} else {
			l.pos += 1
			l.col += 1
		}
	}
	return Token{type = .String, text = l.source[start:l.pos], line = line, col = col}
}

lex_bare :: proc(l: ^Lexer) -> Token {
	start := l.pos
	line := l.line
	col := l.col

	for l.pos < len(l.source) {
		r, width := utf8.decode_rune_in_string(l.source[l.pos:])
		if !is_bare_continue(r) {
			break
		}
		l.pos += width
		l.col += 1
	}

	text := l.source[start:l.pos]

	if text == "true" || text == "false" {
		return Token{type = .Boolean, text = text, line = line, col = col}
	}
	if text == "null" {
		return Token{type = .Null, text = text, line = line, col = col}
	}
	if is_number(text) {
		return Token{type = .Number, text = text, line = line, col = col}
	}
	return Token{type = .Identifier, text = text, line = line, col = col}
}

is_bare_start :: proc(r: rune) -> bool {
	if r >= 'a' && r <= 'z' do return true
	if r >= 'A' && r <= 'Z' do return true
	if r == '_' || r == '-' || r == '+' || r == '.' do return true
	if r >= '0' && r <= '9' do return true
	return unicode.is_alpha(r)
}

is_bare_continue :: proc(r: rune) -> bool {
	if r >= 'a' && r <= 'z' do return true
	if r >= 'A' && r <= 'Z' do return true
	if r >= '0' && r <= '9' do return true
	if r == '_' || r == '-' || r == '.' || r == '+' do return true
	return unicode.is_alpha(r) || unicode.is_digit(r)
}

is_number :: proc(text: string) -> bool {
	if len(text) == 0 do return false

	idx := 0
	if text[idx] == '+' || text[idx] == '-' do idx += 1
	if idx >= len(text) do return false

	if text[idx] == '0' && idx + 1 < len(text) && (text[idx + 1] == 'x' || text[idx + 1] == 'X') {
		idx += 2
		if idx >= len(text) do return false
		for idx < len(text) && is_hex_digit(text[idx]) {
			idx += 1
		}
		return idx == len(text)
	}

	had_digit := false
	for idx < len(text) && text[idx] >= '0' && text[idx] <= '9' {
		idx += 1
		had_digit = true
	}

	if idx < len(text) && text[idx] == '.' {
		idx += 1
		for idx < len(text) && text[idx] >= '0' && text[idx] <= '9' {
			idx += 1
			had_digit = true
		}
	}

	if !had_digit do return false

	if idx < len(text) && (text[idx] == 'e' || text[idx] == 'E') {
		idx += 1
		if idx < len(text) && (text[idx] == '+' || text[idx] == '-') do idx += 1
		if idx >= len(text) do return false
		for idx < len(text) && text[idx] >= '0' && text[idx] <= '9' {
			idx += 1
		}
	}

	return idx == len(text)
}

is_hex_digit :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}
