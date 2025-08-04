//
//
//  KEdit
//
//  Created by KARINO Masatugu on 2025/08/04.
//

#include "ts_language_registry.h"
#include "tree-sitter-ruby.h"

const void *ts_language_ruby(void) {
    return tree_sitter_ruby();
}
