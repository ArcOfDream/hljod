package kdl

import "core:fmt"

Event_Type :: enum {
	Start_Node,
	End_Node,
	Argument,
	Property,
	Start_Children,
	End_Children,
}

Value :: struct {
	raw_text: string,
	type_:    Token_Type,
}

Event :: struct {
	type:  Event_Type,
	name:  string,
	value: Value,
}

Parser_Callback :: #type proc(ctx: rawptr, event: Event) -> (keep_parsing: bool)

Parser :: struct {
	lexer:     Lexer,
	peek_tok:  Token,
	has_peek:  bool,
	had_error: bool,
	err_tok:   Token,
}

parser_init :: proc(p: ^Parser, source: string) {
	lexer_init(&p.lexer, source)
	p.has_peek = false
	p.had_error = false
}

next_token :: proc(p: ^Parser) -> Token {
	if p.has_peek {
		p.has_peek = false
		return p.peek_tok
	}
	return lexer_next(&p.lexer)
}

peek_token :: proc(p: ^Parser) -> Token {
	if !p.has_peek {
		p.peek_tok = lexer_next(&p.lexer)
		p.has_peek = true
	}
	return p.peek_tok
}

set_error :: proc(p: ^Parser) {
	tok := peek_token(p)
	p.err_tok = tok
	p.had_error = true
}

is_value_token :: proc(t: Token_Type) -> bool {
	#partial switch t {
	case .Identifier, .String, .Number, .Boolean, .Null:
		return true
	}
	return false
}

// strip surrounding quotes from string tokens so Value.raw_text points at inner content
clean_value :: proc(tok: Token) -> Value {
	if tok.type == .String && len(tok.text) >= 2 {
		return Value{raw_text = tok.text[1:len(tok.text) - 1], type_ = .String}
	}
	return Value{raw_text = tok.text, type_ = tok.type}
}

// strip surrounding quotes from property key / node name tokens
clean_key :: proc(tok: Token) -> string {
	if tok.type == .String && len(tok.text) >= 2 {
		return tok.text[1:len(tok.text) - 1]
	}
	return tok.text
}

parse :: proc(source: string, callback: Parser_Callback, ctx: rawptr) -> (ok: bool, err: string) {
	p: Parser
	parser_init(&p, source)

	ok = parse_nodes(&p, callback, ctx)

	if p.had_error {
		tok := p.err_tok
		err = fmt.tprintf(
			"parse error at line %d, col %d: unexpected %v ('%s')",
			tok.line,
			tok.col,
			tok.type,
			tok.text,
		)
		return false, err
	}
	return ok, ""
}

parse_nodes :: proc(p: ^Parser, cb: Parser_Callback, ctx: rawptr) -> bool {
	for {
		for {
			tok := peek_token(p)
			if tok.type == .Semicolon || tok.type == .LineComment {
				next_token(p)
			} else {
				break
			}
		}

		tok := peek_token(p)
		#partial switch tok.type {
		case .EOF:
			return true
		case .CloseBrace:
			return true
		case .Slashdash:
			next_token(p)
			for {
				t := peek_token(p)
				if t.type == .Semicolon || t.type == .LineComment {
					next_token(p)
				} else {
					break
				}
			}
			if !parse_node(p, cb, ctx, true) do return false
		case .Identifier, .String, .Number, .Boolean, .Null:
			if !parse_node(p, cb, ctx, false) do return false
		case:
			set_error(p)
			return false
		}
	}
}

parse_node :: proc(p: ^Parser, cb: Parser_Callback, ctx: rawptr, slashdashed: bool) -> bool {
	name_tok := next_token(p)
	if !is_value_token(name_tok.type) {
		set_error(p)
		return false
	}

	if !slashdashed {
		if !cb(ctx, Event{type = .Start_Node, name = clean_key(name_tok)}) {return false}
	}

	loop: for {
		tok := peek_token(p)

		if tok.type == .LineComment {
			next_token(p)
			continue
		}

		#partial switch tok.type {
		case .Semicolon, .EOF:
			break loop

		case .CloseBrace:
			break loop

		case .Slashdash:
			next_token(p)
			next_tok := peek_token(p)
			if next_tok.type == .OpenBrace {
				next_token(p)
				skip_to_close(p)
			} else if is_value_token(next_tok.type) {
				skip_value_or_prop(p)
			}

		case .OpenBrace:
			next_token(p)
			if !slashdashed {
				if !cb(ctx, Event{type = .Start_Children}) {return false}
			}
			if !parse_nodes(p, cb, ctx) do return false
			close := next_token(p)
			if close.type != .CloseBrace {
				set_error(p)
				return false
			}
			if !slashdashed {
				if !cb(ctx, Event{type = .End_Children}) {return false}
			}
			break loop

		case:
			if is_value_token(tok.type) {
				value_tok := next_token(p)
				eq := peek_token(p)
				if eq.type == .Equals {
					next_token(p) // consume =
					val_tok := next_token(p)
					if !is_value_token(val_tok.type) {
						set_error(p)
						return false
					}
					if !slashdashed {
						if !cb(
							ctx,
							Event {
								type = .Property,
								name = clean_key(value_tok),
								value = clean_value(val_tok),
							},
						) {return false}
					}
				} else {
					if !slashdashed {
						if !cb(
							ctx,
							Event{type = .Argument, value = clean_value(value_tok)},
						) {return false}
					}
				}
			} else {
				set_error(p)
				return false
			}
		}
	}

	if !slashdashed {
		if !cb(ctx, Event{type = .End_Node, name = clean_key(name_tok)}) {return false}
	}

	return true
}

skip_value_or_prop :: proc(p: ^Parser) {
	tok := peek_token(p)
	if !is_value_token(tok.type) do return
	next_token(p)
	if peek_token(p).type == .Equals {
		next_token(p)
		val_tok := next_token(p)
		if !is_value_token(val_tok.type) do set_error(p)
	}
}

skip_to_close :: proc(p: ^Parser) {
	depth := 1
	for depth > 0 {
		tok := next_token(p)
		#partial switch tok.type {
		case .EOF:
			return
		case .OpenBrace:
			depth += 1
		case .CloseBrace:
			depth -= 1
		}
	}
}
