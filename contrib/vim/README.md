# Vim Syntax Highlighting for Mere Recipes

This directory contains Vim syntax highlighting for Mere Linux recipe files.

## Installation

### Option 1: Manual Installation

```bash
# Copy syntax file
mkdir -p ~/.vim/syntax
cp mere-recipe.vim ~/.vim/syntax/

# Copy filetype detection
mkdir -p ~/.vim/ftdetect
cp ftdetect-mere-recipe.vim ~/.vim/ftdetect/
```

### Option 2: Using vim-plug

Add to your `~/.vimrc`:

```vim
Plug '/path/to/mere/contrib/vim', { 'rtp': '.' }
```

Then run `:PlugInstall`

### Option 3: Manual ~/.vimrc Configuration

Add to your `~/.vimrc`:

```vim
" Mere recipe syntax
au BufRead,BufNewFile recipe.kdl setfiletype mere-recipe
au BufRead,BufNewFile recipe.kdl set syntax=mere-recipe
```

And copy the syntax file:

```bash
mkdir -p ~/.vim/syntax
cp mere-recipe.vim ~/.vim/syntax/
```

## Features

The syntax file provides highlighting for:

- **Recipe nodes**: `recipe`, `vars`, `source`, `prepare`, `build`, `check`, `install`, `package`, and package child `service`
- **Recipe/package/service properties**: metadata, `files`, `strip`, service commands, dependencies, logging, and environment blocks
- **Variable interpolation**: `${recipe.name}`, `${vars.custom}`, `${MERE_PKG_NAME}`, etc.
- **Shell script highlighting**: Full shell syntax highlighting inside `script` blocks (both `script "..."` and `script r#"..."#`)
- **Strings**: Regular strings and raw strings (`r#"..."#`)
- **Comments**: `//` and `/* */`
- **Built-in variables**: All MERE_* environment variables and recipe variables
- **Common values**: Architecture names (`x86_64`, `aarch64`) and license identifiers (`GPL`, `MIT`, `BSD`, etc.)

### Shell Script Highlighting

The syntax file includes embedded shell syntax highlighting for script blocks:

```kdl
build {
    script r#"
        ./configure --prefix=/usr    # Shell commands are highlighted
        make -j$(nproc)              # Shell variables work
        echo "Building ${MERE_PKG_NAME}"  # Mere variables also work
    "#
}
```

Both shell syntax (commands, operators, variables) and Mere variable interpolation (`${...}`) work together seamlessly.

## Testing

Open any `recipe.kdl` file in vim to see syntax highlighting:

```bash
vim core/packages/busybox/recipe.kdl
```

## Customization

You can customize colors by adding to your `~/.vimrc`:

```vim
" Example: Make top-level nodes bold
hi mereTopNode term=bold cterm=bold gui=bold

" Example: Use different color for variable interpolation
hi mereVarInterp ctermfg=yellow guifg=#ffff00
```
