type Token =
  | { type: "term"; value: string; phrase: boolean }
  | { type: "operator"; value: "AND" | "OR" | "NOT" }
  | { type: "left" | "right" };

type Expression =
  | { type: "term"; words: string[]; phrase: boolean }
  | { type: "not"; child: Expression }
  | { type: "and" | "or"; left: Expression; right: Expression };

const wordPattern = /[\p{L}\p{N}]+/gu;

function tokenize(input: string): Token[] {
  const tokens: Token[] = [];
  let index = 0;
  while (index < input.length) {
    const character = input[index];
    if (/\s/.test(character)) { index += 1; continue; }
    if (character === "(") { tokens.push({ type: "left" }); index += 1; continue; }
    if (character === ")") { tokens.push({ type: "right" }); index += 1; continue; }
    if (character === '"') {
      const end = input.indexOf('"', index + 1);
      if (end < 0) throw new Error("Close the quoted phrase before applying this Boolean search.");
      const value = input.slice(index + 1, end).trim();
      if (!value) throw new Error("Quoted phrases cannot be empty.");
      tokens.push({ type: "term", value, phrase: true });
      index = end + 1;
      continue;
    }
    let end = index;
    while (end < input.length && !/[\s()"]/.test(input[end])) end += 1;
    const value = input.slice(index, end);
    const upper = value.toUpperCase();
    if (upper === "AND" || upper === "OR" || upper === "NOT") tokens.push({ type: "operator", value: upper });
    else tokens.push({ type: "term", value, phrase: false });
    index = end;
  }
  return tokens;
}

class Parser {
  private index = 0;
  private readonly tokens: Token[];
  constructor(tokens: Token[]) { this.tokens = tokens; }

  parse() {
    if (!this.tokens.length) throw new Error("Enter at least one word to search.");
    const expression = this.parseOr();
    if (this.index !== this.tokens.length) throw new Error("Check the Boolean operators and parentheses.");
    return expression;
  }

  private current() { return this.tokens[this.index]; }
  private consume() { return this.tokens[this.index++]; }

  private parseOr(): Expression {
    let left = this.parseAnd();
    while (true) {
      const token = this.current();
      if (token?.type !== "operator" || token.value !== "OR") break;
      this.consume();
      left = { type: "or", left, right: this.parseAnd() };
    }
    return left;
  }

  private parseAnd(): Expression {
    let left = this.parseUnary();
    while (this.index < this.tokens.length) {
      const token = this.current();
      if (token.type === "right" || (token.type === "operator" && token.value === "OR")) break;
      if (token.type === "operator" && token.value === "AND") this.consume();
      else if (token.type === "operator" && token.value !== "NOT") throw new Error("Check the Boolean operators in this search.");
      left = { type: "and", left, right: this.parseUnary() };
    }
    return left;
  }

  private parseUnary(): Expression {
    const token = this.current();
    if (token?.type === "operator" && token.value === "NOT") {
      this.consume();
      return { type: "not", child: this.parseUnary() };
    }
    if (token?.type === "left") {
      this.consume();
      const child = this.parseOr();
      if (this.current()?.type !== "right") throw new Error("Close every parenthesis before applying this Boolean search.");
      this.consume();
      return child;
    }
    if (token?.type !== "term") throw new Error("Add a word or phrase after the Boolean operator.");
    this.consume();
    const words = token.value.match(wordPattern) ?? [];
    if (!words.length) throw new Error("Search terms must contain letters or numbers.");
    return { type: "term", words, phrase: token.phrase };
  }
}

function compileExpression(expression: Expression): string {
  if (expression.type === "term") {
    const terms = expression.words.map((word) => `'${word.toLocaleLowerCase().replaceAll("'", "")}'`);
    return terms.length === 1 ? terms[0] : `(${terms.join(expression.phrase ? " <-> " : " & ")})`;
  }
  if (expression.type === "not") return `!(${compileExpression(expression.child)})`;
  const operator = expression.type === "and" ? "&" : "|";
  return `(${compileExpression(expression.left)} ${operator} ${compileExpression(expression.right)})`;
}

export function compileBooleanSearch(input: string) {
  const clean = input.trim();
  if (clean.length > 1000) throw new Error("Boolean searches can contain up to 1,000 characters.");
  return compileExpression(new Parser(tokenize(clean)).parse());
}
