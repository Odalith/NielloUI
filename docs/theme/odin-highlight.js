// Odin syntax highlighting for the book: mdBook's bundled highlight.js has
// no Odin grammar, so register a small one and highlight the Odin blocks
// (```odin) the bundled pass left plain.
(function () {
	if (typeof hljs === "undefined") {
		return;
	}
	hljs.registerLanguage("odin", function (hljs) {
		return {
			name: "Odin",
			keywords: {
				keyword:
					"package import foreign proc struct enum union bit_set map matrix distinct " +
					"if else when for in not_in do switch case break continue fallthrough return " +
					"defer using context or_else or_return or_break or_continue cast transmute auto_cast " +
					"dynamic where",
				literal: "true false nil",
				type:
					"bool b8 b16 b32 b64 int i8 i16 i32 i64 i128 uint u8 u16 u32 u64 u128 uintptr " +
					"f16 f32 f64 complex64 complex128 quaternion256 rune string cstring rawptr typeid any byte",
			},
			contains: [
				hljs.C_LINE_COMMENT_MODE,
				hljs.C_BLOCK_COMMENT_MODE,
				hljs.QUOTE_STRING_MODE,
				{ className: "string", begin: "`", end: "`" },
				{ className: "string", begin: "'", end: "'", illegal: "\\n" },
				hljs.C_NUMBER_MODE,
				{ className: "meta", begin: "#[a-z_]+" },
				{ className: "meta", begin: "@\\(?[a-z_]+" },
				{ className: "title", begin: "\\b[A-Za-z_][A-Za-z0-9_]*(?=\\s*::\\s*(#force_inline\\s+)?proc)" },
			],
		};
	});
	var highlight = hljs.highlightElement || hljs.highlightBlock;
	document.querySelectorAll("code.language-odin").forEach(function (block) {
		block.classList.remove("hljs");
		highlight.call(hljs, block);
	});
})();
