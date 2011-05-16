REBOL [
	Title:   "Red/System compiler"
	Author:  "Nenad Rakocevic"
	File: 	 %compiler.r
	Rights:  "Copyright (C) 2011 Nenad Rakocevic. All rights reserved."
	License: "BSD-3 - https://github.com/dockimbel/Red/blob/master/BSD-3-License.txt"
]

do %linker.r
do %emitter.r

system-dialect: context [
	verbose:  0									;-- logs verbosity level
	job: none									;-- reference the current job object	
	runtime-env: none							;-- hold OS-specific Red/System runtime
	runtime-path: %runtime/
	nl: newline
	
	;errors: [
	;	type	["message" arg1 "and" arg2]
	;]
	
	loader: context [
		verbose: 0
		include-dirs: none
		include-list: make hash! 20
		defs: make block! 100
		
		hex-chars: charset "0123456789ABCDEF"
		
		init: does [
			include-dirs: copy [%runtime/]
			clear include-list
			clear defs
			insert defs <no-match>				;-- required to avoid empty rule (causes infinite loop)
		]
		
		included?: func [file [file!]][
			file: get-modes file 'full-path
			either find include-list file [true][
				append include-list file
				false
			]
		]
		
		find-path: func [file [file!]][
			foreach dir include-dirs [
				if exists? dir/:file [return dir/:file]
			]
			make error! reform ["Include File Access Error:" file]
		]
		
		expand-string: func [src [string! binary!] /local value s e][
			if verbose > 0 [print "running string preprocessor..."]
			
			parse/all/case src [						;-- not-LOAD-able syntax support
				any [
					s: copy value 1 8 hex-chars #"h" e: (		;-- literal hexadecimal support
						e: change/part s to integer! to issue! value e
					) :e
					| skip
				]
			]
		]
		
		expand-block: func [src [block!] /local blk rule name value s e][		
			if verbose > 0 [print "running block preprocessor..."]			
			parse/case src blk: [
				some [
					defs								;-- resolve definitions in a single pass
					| #define set name word! set value skip (
						if verbose > 0 [print [mold name #":" mold value]]
						if word? value [value: to lit-word! value]
						rule: copy/deep [s: _ e: (e: change/part s _ e) :e]
						rule/2: to lit-word! name
						rule/4/4: :value						
						either tag? defs/1 [remove defs][append defs '|]						
						append defs rule
					)
					| s: #include set name file! e: (
						either included? name: find-path name [
							s: skip s 2					;-- already included, skip it
						][
							if verbose > 0 [print ["...including file:" mold name]]
							value: skip process/short name 2	;-- skip Red/System header						
							e: change/part s value e
						]
					) :s
					| into blk
					| skip
				]
			]		
		]
		
		process: func [input [file! string!] /short /local src err path][
			if verbose > 0 [print ["processing" mold either file? input [input]['runtime]]]
			
			if file? input [
				if all [
					%./ <> path: first split-path input	;-- is there a path in the filename?
					not find include-dirs path
				][
					append include-dirs path			;-- register source's dir as include dir
				]
				if error? set/any 'err try [src: as-string read/binary input][	;-- read source file
					print ["File Access Error:" mold disarm err]
				]
			]
			expand-string src: any [src input]			;-- process string-level compiler directives
			
			;TBD: add Red/System header checking here!
			
			if error? set/any 'err try [src: load src][	;-- convert source to blocks
				print ["Syntax Error at LOAD phase:" mold disarm err]
			]
			
			unless short [expand-block src]		;-- process block-level compiler directives		
			src
		]
	]
	
	compiler: context [
		job: 		none								;-- compilation job object
		pc:			none								;-- source code input cursor
		last-type:	none								;-- type of last value from an expression
		locals: 	none								;-- currently compiled function specification block
		verbose:  	0									;-- logs verbosity level
	
		imports: 	   make block! 10					;-- list of imported functions
		bodies:	  	   make hash!  40					;-- list of functions to compile [name [specs] [body]...]
		globals:  	   make hash!  40					;-- list of globally defined symbols from scripts
		aliased-types: make hash!  10					;-- list of aliased type definitions
		
		pos:		none								;-- validation rules cursor for error reporting
		return-def: to-set-word 'return					;-- return: keyword
		fail:		[end skip]							;-- fail rule
		rule: w:	none								;-- global parsing rules helpers
		
		functions: to-hash [
		;--Name--Arity--Type----Cc--Specs--		   Cc = Calling convention
			+		[2	op		- [a [number! pointer!] b [number! pointer!] return: [integer!]]]
			-		[2	op		- [a [number! pointer!] b [number! pointer!] return: [integer!]]]
			*		[2	op		- [a [number!] b [number!] return: [integer!]]]
			/		[2	op		- [a [number!] b [number!] return: [integer!]]]
			and		[2	op		- [a [number!] b [number!] return: [integer!]]]
			or		[2	op		- [a [number!] b [number!] return: [integer!]]]
			xor		[2	op		- [a [number!] b [number!] return: [integer!]]]
			//		[2	op		- [a [number!] b [number!] return: [integer!]]]		;-- modulo
			;>>		[2	op		- [a [number!] b [number!] return: [integer!]]]		;-- shift left
			;<<		[2	op		- [a [number!] b [number!] return: [integer!]]]		;-- shift right
			=		[2	op		- [a b return: [logic!]]]
			<>		[2	op		- [a b return: [logic!]]]
			>		[2	op		- [a [number! pointer!] b [number! pointer!] return: [logic!]]]
			<		[2	op		- [a [number! pointer!] b [number! pointer!] return: [logic!]]]
			>=		[2	op		- [a [number! pointer!] b [number! pointer!] return: [logic!]]]
			<=		[2	op		- [a [number! pointer!] b [number! pointer!] return: [logic!]]]
			not		[1	inline	- [a [logic! integer! ] return: [logic! integer!]]]
			size?	[1  inline  - [value return: [integer!]]]
		]
		
		user-functions: tail functions	;-- marker for user functions
		
		struct-syntax: [
			pos: opt [into ['align integer! opt ['big | 'little]]]	;-- struct's attributes
			pos: any [word! into type-spec]							;-- struct's members
		]
		
		pointer-syntax: ['integer!]
		
		type-syntax: [
			'int8! | 'int16! | 'int32! | 'integer! | 'uint8! | 'uint16! | 'uint32!
			| 'c-string! | 'logic! | 'byte!
			| 'pointer! into [pointer-syntax]
			| 'struct!  into [struct-syntax]
		]

		type-spec: [
			pos: some type-syntax | set w word! (				;-- multiple types allowed for internal usage
				rule: either find aliased-types w [[skip]][fail]	;-- make the rule fail if not found
			) rule
		]		
		
		keywords: [
			;&			 []
			as			 [comp-as]
			size? 		 [comp-size?]
			if			 [comp-if]
			either		 [comp-either]
			until		 [comp-until]
			while		 [comp-while]
			any			 [comp-expression-list]
			all			 [comp-expression-list/_all]
			exit		 [comp-exit]
			return		 [comp-exit/value]
			null	 	 [also 0 pc: next pc]
			struct! 	 [also 'struct! pc: next pc]	;@@ was required for 'alias (still needed?)
			true		 [also true pc: next pc]		;-- converts word! to logic!
			false		 [also false pc: next pc]		;-- converts word! to logic!
			func 		 [comp-function]
			function 	 [comp-function]
			alias 		 [comp-alias]
			struct 		 [comp-struct]
			pointer 	 [comp-pointer]
		]
		
		throw-error: func [err [word! string!]][
			print [
				"***"
				either word? err [
					join uppercase/part mold err 1 " error"
				][err]
			]
			print ["*** at: " mold copy/part pc 4]
			clean-up
			halt
		]
		
		encode-cond-test: func [value [logic!]][
			pick [<true> <false>] value
		]
		
		literal?: func [value][not any [word? value value = <last>]]
		
		decode-cond-test: func [value [tag!]][
			select [<true> #[true] <false> #[false]] value
		]
		
		get-return-type: func [name [word!] /local type][
			type: select functions/:name/4 return-def
			unless type [
				pc: any [find/reverse pc name pc]
				throw-error reform ["return type missing in function:" name]
			]
			type/1
		]
		
		set-last-type: func [spec [block!]][
			if spec: select spec return-def [last-type: spec/1]
		]
		
		get-variable-spec: func [name [word!]][
			any [
				all [locals select locals name]
				select globals name
			]
		]
		
		resolve-type: func [name [word!] /with parent [block! none!] /local type][
			type: any [
				all [parent select parent name]
				get-variable-spec name
			]
			if all [not type find functions name][
				return [function!]
			]
			unless find emitter/datatypes type/1 [
				type: select aliased-types type/1
			]
			;;;; Temporary workaround for lack of proper pointer! declaration support in functions @@
			if all [type/1 = 'pointer! not type/2][type: [pointer! [integer!]]]
			;;;; @@
			type
		]
		
		resolve-path-type: func [path [path! set-path!] /parent prev][
			type: either parent [
				resolve-type/with path/1 prev
			][
				resolve-type path/1
			]
			either tail? skip path 2 [
				switch/default type/1 [
					c-string! ['byte!]
					pointer!  [
						;TBD: check-pointer-path
						'pointer!
					]
					struct!   [first select type/2 path/2]
				][
					pc: find/reverse/only pc path
					throw-error "invalid path value"
				]
			][
				resolve-path-type/parent next path second type
			]
		]
		
		get-mapped-type: func [value][
			case [
				value = <last>  [last-type]
				tag?    value	['logic!]
				logic?   value	['logic!]
				paren?  value	[reduce [to word! join value/1 #"!" value/2]]
				word?   value 	[resolve-type value]
				char?   value	['byte!]
				string? value	['c-string!]
				path?   value	[resolve-path-type value]
				block?  value	[get-return-type value/1]
				'else 			[type?/word value]	;@@ should throw an error?
			]	
		]
		
		add-symbol: func [name [word!] value /local type][
			type: get-mapped-type value
			append globals reduce [name type: compose [(type)]]
			type
		]
		
		add-function: func [type [word!] spec [block!] cc [word!] /local name arity][		
			if find functions name: to word! spec/1 [
				;TBD: symbol already defined
			]
			;TBD: check spec syntax (here or somewhere else)
			arity: either pos: find spec/3 /local [			; @@ won't work with inferencing
				(index? pos) -  1 / 2
			][
				(length? spec/3) / 2
			]
			if find spec/3 return-def [arity: max 0 arity - 1]
			repend functions [
				name reduce [arity type cc new-line/all spec/3 off]
			]
		]
		
		check-specs: func [name specs /local type spec-type attribs value][
			unless block? specs [throw-error 'syntax]
			attribs: ['infix]

			unless parse specs [
				pos: opt [into [some attribs]]				;-- functions attributes
				pos: any [pos: word! into type-spec]		;-- arguments definition
				pos: opt [									;-- return type definition				
					set value set-word! (					
						rule: pick reduce [[into type-spec] fail] value = return-def
					) rule
				]
				pos: opt [/local some [pos: word! into type-spec]] ;-- local variables definition
			][			
				throw-error rejoin ["invalid definition for function " name ": " mold pos]
			]		
		]
		
		check-body: func [body][
			case/all [
				not block? :body [throw-error 'syntax 'block-expected]
				empty? body  	 [throw-error 'syntax 'empty-block]
			]
		]
		
		fetch-into: func [code [block! paren!] body [block!] /local save-pc][		;-- compile sub-block
			save-pc: pc
			pc: code
			do body
			pc: next save-pc
		]
		
		fetch-func: func [name /local specs type][
			;check if name is word and taken
			check-specs name pc/2
			specs: pc/2
			type: 'native
			if all [
				not empty? specs
				block? specs/1
				find specs/1 'infix
			][
				;TBD: check for two arguments presence
				specs: next specs				;@@ quick'n dirty workaround
				type: 'infix				
			]
			add-function type reduce [name none specs] 'stdcall
			emitter/add-native to word! name
			repend bodies [to word! name specs pc/3]
			pc: skip pc 3
		]
		
		reduce-logic-tests: func [expr /local test value][
			test: [logic? expr/2 logic? expr/3]
			
			if all [
				block? expr
				find [= <>] expr/1
				any test
			][
				expr: either all test [
					do expr								;-- let REBOL reduce the expression
				][
					expr: copy expr
					if any [
						all [expr/1 = '= not all [expr/2 expr/3]]
						all [expr/1 = first [<>] any [expr/2 = true expr/3 = true]]
					][
						insert expr 'not
					]
					remove-each v expr [any [find [= <>] v logic? v]]
					if any [
						all [word? expr/1 get-variable-spec expr/1]
						paren? expr/1
						block? expr/1
					][
						expr: expr/1					;-- remove outer brackets if variable
					]
					expr
				]
			]
			expr
		]
				
		comp-directive: has [list reloc][
			switch/default pc/1 [
				#import [
					unless block? pc/2 [
						;TBD: syntax error
					]
					foreach [lib cc specs] pc/2 [		;-- cc = calling convention
						;TBD: check lib/specs validity
						unless list: select imports lib [
							repend imports [lib list: make block! 10]
						]
						forskip specs 3 [
							repend list [specs/2 reloc: make block! 1]
							add-function 'import specs cc
							emitter/import-function to word! specs/1 reloc
						]						
					]				
					pc: skip pc 2
				]
				#syscall [
					unless block? pc/2 [
						;TBD: syntax error
					]
					foreach [name code specs] pc/2 [
						;TBD: check call/code/specs validity
						add-function 'syscall reduce [name none specs] 'syscall
						append last functions code		;-- extend definition with syscode
						;emitter/import-function to word! specs/1 reloc
					]				
					pc: skip pc 2
				]
				#define  [pc: skip pc 3]				;-- preprocessed before
				#include [pc: skip pc 2]				;-- preprocessed before
			][
				;TBD: unknown directive error
			]
		]
		
		comp-reference-literal: has [value][
			value: to paren! reduce [pc/1 pc/2]
			unless find [set-word! set-path!] type?/word pc/-1 [
				throw-error "assignment expected for struct value"
			]
			pc: skip pc 2
			value
		]
		
		comp-struct: does [		
			unless parse pos: pc/2 struct-syntax [
				throw-error reform ["invalid struct syntax:" mold pos]
			]
			comp-reference-literal
		]
		
		comp-pointer: does [
			unless parse pos: pc/2 pointer-syntax [
				throw-error reform ["invalid pointer syntax:" mold pos]
			]
			comp-reference-literal
		]
		
		comp-as: has [type value][
			type: pc/2
			pc: skip pc 2
			value: fetch-expression
			last-type: either block? type [type][reduce [type]]
			value
		]
		
		comp-alias: does [
			;TBD: check specs block validity
			repend aliased-types [
				to word! pc/-1
				either find [struct! pointer!] to word! pc/2 [
					also reduce [pc/2 pc/3] pc: skip pc 3	
				][
					also pc/2 pc: skip pc 2
				]
			]
			none
		]
		
		comp-size?: has [type value][
			pc: next pc
			value: pc/1
			if any [find [true false] value][
				value: do value
			]
			type: switch/default type?/word value [
				word!	  [resolve-type value]
				path!	  [resolve-path-type value]
				set-path! [resolve-path-type value]
			][
				get-mapped-type value
			]
			unless block? type [type: reduce [type]]
			emitter/get-size type value
			last-type: get-return-type 'size?
			pc: next pc
			<last>
		]
		
		comp-exit: func [/value /local expr][
			pc: next pc
			if value [
				expr: fetch-expression/final/keep		;-- compile expression to return						
				;TBD: check return type validity here
			]
			emitter/target/emit-exit
			none
		]
		
		comp-function: does [
			fetch-func pc/-1
			none
		]

		comp-block-chunked: func [/only /test /local expr][
			emitter/chunks/start
			expr: either only [
				fetch-expression/final					;-- returns first expression
			][
				comp-block/final						;-- returns last expression
			]
			if test [expr: check-logic expr]
			reduce [
				expr 
				emitter/chunks/stop						;-- returns a chunk block!
			]
		]
		
		check-logic: func [expr][						;-- preprocess logic values
			switch/default type?/word expr [
				logic! [[#[true]]]
				word!  [
					type: first resolve-type expr					
					unless find [logic! function!] type [
						throw-error "expected logic! variable or conditional expression"
					]
					if all [
						type = 'function!
						'logic! <> get-return-type expr
					][
						throw-error reform [
							"expecting a logic! return value from function"
							mold expr
						]
					]
					emitter/target/emit-operation '= [<last> 0]
					[#[true]]
				]
				block! [
					either find emitter/target/comparison-op expr/1 [
						expr
					][
						check-logic expr/1
					]
				]
				tag! [
					either expr <> <last> [ [#[true]] ][expr]
				]
			][expr]
		]
		
		comp-if: has [expr unused chunk][		
			pc: next pc
			expr: fetch-expression/final				;-- compile condition expression
			expr: check-logic expr		
			check-body pc/1								;-- check TRUE block
	
			set [unused chunk] comp-block-chunked		;-- compile TRUE block
			emitter/branch/over/on chunk expr/1			;-- insert IF branching			
			emitter/merge chunk		
			<last>
		]
		
		comp-either: has [expr unused c-true c-false offset][
			pc: next pc
			expr: fetch-expression/final				;-- compile condition
			expr: check-logic expr
			check-body pc/1								;-- check TRUE block
			check-body pc/2								;-- check FALSE block
			
			set [unused c-true]  comp-block-chunked		;-- compile TRUE block		
			set [unused c-false] comp-block-chunked		;-- compile FALSE block
		
			offset: emitter/branch/over c-false
			emitter/branch/over/adjust/on c-true negate offset expr/1	;-- skip over JMP-exit
			emitter/merge emitter/chunks/join c-true c-false
			<last>
		]
		
		comp-until: has [expr chunk][
			pc: next pc
			check-body pc/1
			set [expr chunk] comp-block-chunked/test
			emitter/branch/back/on chunk expr/1	
			emitter/merge chunk			
			<last>
		]
		
		comp-while: has [expr unused cond body  offset bodies][
			pc: next pc
			check-body pc/1								;-- check condition block
			check-body pc/2								;-- check body block
			
			set [expr cond]   comp-block-chunked/test	;-- Condition block
			set [unused body] comp-block-chunked		;-- Body block
			
			if logic? expr/1 [expr: [<>]]				;-- re-encode test op
			offset: emitter/branch/over body			;-- Jump to condition
			bodies: emitter/chunks/join body cond
			emitter/branch/back/on/adjust bodies reduce [expr/1] offset ;-- Test condition, exit if FALSE
			emitter/merge bodies
			<last>
		]
		
		comp-expression-list: func [/_all /local list offset bodies op][
			pc: next pc
			check-body pc/1								;-- check body block
			
			list: make block! 8
			fetch-into pc/1 [
				while [not tail? pc][					;-- comp all expressions in chunks
					append/only list comp-block-chunked/only/test
				]
			]
			list: back tail list
			set [offset bodies] emitter/chunks/make-boolean			;-- emit ending FALSE/TRUE block
			if _all [emitter/branch/over/adjust bodies offset/1]	;-- conclude by a branch on TRUE
			offset: pick offset not _all				;-- branch to TRUE or FALSE 
			
			until [										;-- left join all expr in reverse order			
				op: either logic? list/1/1/1 [first [<>]][list/1/1/1]
				unless _all [op: reduce [op]]			;-- do not invert the test if ANY
				emitter/branch/over/on/adjust bodies op offset		;-- first emit branch				
				bodies: emitter/chunks/join list/1/2 bodies			;-- then left join expr
				also head? list	list: back list
			]	
			emitter/merge bodies
			encode-cond-test not _all					;-- special encoding
		]
		
		comp-assignment: has [name value][
			name: pc/1
			pc: next pc
			either none? value: fetch-expression [		;-- explicitly test for none!
				none
			][				
				new-line/all reduce [name value] no
			]
		]
		
		comp-get-word: has [name spec][
			either all [
				spec: select functions name: to word! pc/1
				spec/2 = 'native
			][
				emitter/target/emit-get-address name
				pc: next pc
				<last>
			][
				throw-error "get-word syntax only reserved for native functions for now"
			]
		]
	
		comp-word: has [entry args n name][
			case [
				entry: select keywords pc/1 [		;-- reserved word
					do entry
				]
				any [
					all [locals find locals pc/1]
					find globals pc/1
				][										;-- it's a variable
					also pc/1 pc: next pc
				]
				entry: find functions name: pc/1 [
					pc: next pc							;-- it's a function		
					args: make block! n: entry/2/1
					loop n [							;-- fetch n arguments
						append/only args fetch-expression	;TBD: check arg types!
					]
					head insert args name
				]
				'else [throw-error "undefined symbol"]
			]
		]
		
		order-args: func [tree [block!] /local func? name type][
			if all [
				func?: not find [set-word! set-path!] type?/word tree/1
				name: to word! tree/1
				find [import native infix] functions/:name/2
				find [stdcall cdecl gcc45] functions/:name/3
			][
				reverse next tree
			]
			foreach v next tree [if block? v [order-args v]]	;-- recursive processing
		]
		
		comp-expression: func [
			tree [block!] /keep
			/local name value data offset body args prepare-value type
		][
			prepare-value: [
				value: either block? tree/2 [
					comp-expression/keep tree/2
					<last>
				][
					tree/2
				]
				either all [tag? value value <> <last>][	;-- special encoding for ALL/ANY
					data: true
					value: <last>
				][
					data: value
				]
				if path? value [
					emitter/access-path value none
					value: <last>
				]
			]
			switch/default type?/word tree/1 [
				set-word! [
					name: to word! tree/1
					do prepare-value
					unless type: get-variable-spec name [	;-- test if known variable (local or global)
						type: add-symbol name data			;-- if unknown add it to global context
					]
					emitter/store name value type
				]
				set-path! [
					do prepare-value
					resolve-path-type tree/1			;-- check path validity
					;TBD: raise error if ANY/ALL passed as argument				
					emitter/access-path tree/1 value
				]
			][
				name: to word! tree/1
				args: next tree
				if all [tag? args/1 args/1 <> <last>][	;-- special encoding for ALL/ANY
					if 1 < length? args [
						throw-error reform [
							"function" name
							"requires only one argument when passing ANY/ALL expression"
						]
					]									
					args/1: <last>
				]			
				type: emitter/target/emit-call name args
				if type [last-type: type]
				
				if all [keep last-type = 'logic!][
					emitter/logic-to-integer name		;-- runtime logic! conversion before storing
				]
			]
		]
		
		infix?: func [pos [block! paren!] /local specs][
			all [
				not tail? pos
				word? pos/1
				specs: select functions pos/1
				find [op infix] specs/2
			]
		]
		
		check-infix-operators: has [pos][
			if infix? pc [exit]							;-- infix op already processed,
														;-- or used in prefix mode.
			if infix? next pc [
				either find [set-word! set-path! struct!] type?/word pc/1 [
					throw-error "can't use infix operator here"
				][
					pos: 0								;-- relative index of next infix op
					until [								;-- search for all dependent infix op
						pos: pos + 2					;-- target next infix possible position
						insert pc pc/:pos				;-- transform to prefix notation
						remove at pc pos + 1
						not infix? at pc pos + 2		;-- exit when no more infix op found
					]
				]
			]
		]
		
		fetch-expression: func [/final /keep /local expr pass][
			check-infix-operators
			if verbose >= 4 [print ["<<<" mold pc/1]]
			pass: [also pc/1 pc: next pc]
			
			expr: switch/default type?/word pc/1 [
				set-word!	[comp-assignment]
				word!		[comp-word]
				get-word!	[comp-get-word]
				path! 		[do pass]
				set-path!	[comp-assignment]
				paren!		[comp-block]
				char!		[do pass]
				integer!	[do pass]
				decimal! 	[do pass]
				string!		[do pass]
				block!		[do pass]					;-- struct! and pointer! specs
				struct!		[do pass]					;-- literal struct! value
			][			
				throw-error "datatype not allowed"
			]
			expr: reduce-logic-tests expr
			
			if final [
				if verbose >= 3 [?? expr]
				case [
					block? expr [
						order-args expr
						either keep [
							comp-expression/keep expr
						][
							comp-expression expr
						]
					]
					not find [none! tag!] type?/word expr [
						emitter/target/emit-load expr
					]
				]
			]
			expr
		]
		
		comp-block: func [/final /local expr][
			fetch-into pc/1 [
				while [not tail? pc][
					expr: either final [
						fetch-expression/final
					][
						fetch-expression
					]
				]
			]
			expr
		]
		
		comp-dialect: does [
			while [not tail? pc][
				case [
					issue? pc/1 [comp-directive]
					pc/1 = 'comment [pc: skip pc 2]
					'else [fetch-expression/final]
				]
			]
		]
		
		comp-func-body: func [name [word!] spec [block!] body [block!] /local args-size][
			locals: spec
			args-size: emitter/enter name locals
			pc: body
			comp-dialect
			emitter/leave name locals args-size
			locals: none
		]
		
		comp-natives: does [
			if verbose >= 2 [print "^/---^/Compiling native functions^/---"]
			foreach [name spec body] bodies [
				if verbose >= 2 [
					print [
						"---------------------------------------^/"
						"function:" name newline
						"---------------------------------------"
					]
				]
				comp-func-body name spec body
			]
			if verbose >= 2 [print ""]
			emitter/reloc-native-calls
		]
		
		comp-header: does [
			unless pc/1 = 'RED/System [
				;TBD: syntax error
			]
			unless block? pc/2 [
				;TBD: syntax error
			]
			pc: skip pc 2
		]

		run: func [src [block!] /no-header][
			pc: src
			unless no-header [comp-header]
			comp-dialect
		]
		
		finalize: does [
			comp-natives
		]
	]
	
	set-verbose-level: func [level [integer!]][
		foreach ctx reduce [
			self
			loader
			compiler
			emitter
			emitter/target
			linker
		][
			ctx/verbose: level
		]
	]
	
	output-logs: does [
		case/all [
			verbose >= 1 [
				print [
					nl
					"-- compiler/globals --" nl mold new-line/all/skip to-block compiler/globals yes 2 nl
					"-- emitter/symbols --"  nl mold emitter/symbols nl
				]
			]
			verbose >= 2 [
				print [
					"-- compiler/functions --" nl mold compiler/functions nl
					"-- emitter/stack --"	   nl mold emitter/stack nl
				]
			]
			verbose >= 3 [
				print [
					"-- emitter/code-buf --" nl mold emitter/code-buf nl
					"-- emitter/data-buf --" nl mold emitter/data-buf nl
					"as-string:"        	 nl mold as-string emitter/data-buf nl
				]
			]
		]
	]
	
	comp-runtime: func [type [word!]][
		compiler/run/no-header loader/process runtime-env/:type
	]
	
	set-runtime: func [job [object!]][
		runtime-env: load switch job/format [
			PE     [runtime-path/win32.r]
			ELF    [runtime-path/linux.r]
			;Mach-o [runtime-path/posix.r]
		]
	]
	
	clean-up: does [
		clear compiler/imports
		clear compiler/bodies
		clear compiler/globals
		clear compiler/aliased-types
		clear compiler/user-functions
	]
	
	make-job: func [opts [object!] file [file!] /local job][
		file: last split-path file			;-- remove path
		file: to-file first parse file "."	;-- remove extension
		
		job: construct/with third opts linker/job-class	
		job/output: file
		job
	]
	
	dt: func [code [block!] /local t0][
		t0: now/time/precise
		do code
		now/time/precise - t0
	]
	
	options-class: context [
		link?: 		no					;-- yes = invoke the linker and finalize the job
		build-dir:	%builds/			;-- where to place compile/link results
		format:		select [			;-- file format
						3	'PE				;-- Windows
						4	'ELF			;-- Linux
						5	'Mach-o			;-- Mac OS X
					] system/version/4
		type:		'exe				;-- file type ('exe | 'dll | 'lib | 'obj)
		target:		'IA32				;-- CPU target
		verbosity:	0					;-- logs verbosity level
		sub-system:	'console			;-- 'GUI | 'console
	]
	
	compile: func [
		files [file! block!]			;-- source file or block of source files
		/options
			opts [object!]
		/local
			comp-time link-time err src
	][
		comp-time: dt [
			unless block? files [files: reduce [files]]
			emitter/init opts/link? job: make-job opts last files	;-- last file's name is retained for output
			compiler/job: job
			set-runtime job
			set-verbose-level opts/verbosity
			
			loader/init
			comp-runtime 'prolog
			
			foreach file files [compiler/run loader/process file]

			comp-runtime 'epilog
			compiler/finalize			;-- compile all functions
		]
		if verbose >= 4 [
			print [
				"-- emitter/code-buf (empty addresses):"
				nl mold emitter/code-buf nl
			]
		]

		if opts/link? [
			link-time: dt [
				job/symbols: emitter/symbols
				job/sections: compose/deep [
					code   [- 	(emitter/code-buf)]
					data   [- 	(emitter/data-buf)]
					import [- - (compiler/imports)]
				]
				linker/build/in job opts/build-dir
			]
		]
		output-logs
		if opts/link? [clean-up]

		also
			reduce [comp-time link-time any [all [job/buffer length? job/buffer] 0]]
			compiler/job: job: none
	]
]