if has('win32') || has('win64')
    let s:PATH_SEP =  '\'
    function! s:is_absolute_path(path) abort
        return a:path =~# '^[a-zA-Z]:[/\\]'
    endfunction
else
    let s:PATH_SEP =  '/'
    function! s:is_absolute_path(path) abort
        return a:path[0] ==# '/'
    endfunction
endif

let g:committia#git#cmd = get(g:, 'committia#git#cmd', 'git')
let g:committia#git#diff_cmd = get(g:, 'committia#git#diff_cmd', 'diff -u --cached --no-color --no-ext-diff')
let g:committia#git#status_cmd = get(g:, 'committia#git#status_cmd', '-c color.status=false status -b')

" Experimental: extract diff and status from commit message template when
" using git commit --verbose, particularly useful when amending commits
let g:committia#git#use_verbose = get(g:, 'committia#git#use_verbose', 0)

try
    silent call vimproc#version()

    " Note: vimproc exists
    function! s:system(cmd) abort
        let out = vimproc#system(a:cmd)
        if vimproc#get_last_status()
            throw printf("Failed to execute command '%s': %s", a:cmd, out)
        endif
        return out
    endfunction
catch /^Vim\%((\a\+)\)\=:E117/
    function! s:system(cmd) abort
        let out = system(a:cmd)
        if v:shell_error
            throw printf("Failed to execute command '%s': %s", a:cmd, out)
        endif
        return out
    endfunction
endtry

if !executable(g:committia#git#cmd)
    echoerr g:committia#git#cmd . ' command is not found. Please check g:committia#git#cmd'
endif

function! s:extract_first_line(str) abort
    let i = stridx(a:str, "\r")
    if i > 0
        return a:str[: i - 1]
    endif
    let i = stridx(a:str, "\n")
    if i > 0
        return a:str[: i - 1]
    endif
    return a:str
endfunction

function! s:search_git_dir_and_work_tree() abort
    " Use environment variables if set
    if !empty($GIT_DIR) && !empty($GIT_WORK_TREE)
        if !isdirectory($GIT_WORK_TREE)
            throw 'Directory specified with $GIT_WORK_TREE does not exist: ' . $GIT_WORK_TREE
        endif
        return [$GIT_DIR, $GIT_WORK_TREE]
    endif

    " '/.git' is unnecessary under submodule directory.
    let matched = matchlist(expand('%:p'), '[\\/]\.git[\\/]\%(\(modules\|worktrees\)[\\/].\+[\\/]\)\?\%(COMMIT_EDITMSG\|MERGE_MSG\)$')
    if len(matched) > 1
        let git_dir = expand('%:p:h')

        if matched[1] ==# 'worktrees'
            " Note:
            " This was added in #31. I'm not sure that the format of gitdir file
            " is fixed. Anyway, it works for now.
            let work_tree = fnamemodify(readfile(git_dir . '/gitdir')[0], ':h')
            return [git_dir, work_tree]
        endif

        " Avoid executing Git command in git-dir because `git rev-parse --show-toplevel`
        " does not return the repository root. To handle work-tree properly,
        " set $CWD to the parent of git-dir, which is outside of the
        " git-dir. (#39)
        let cwd_saved = getcwd()
        let cwd = fnamemodify(git_dir, ':h')
        if cwd_saved !=# cwd
            execute 'lcd' cwd
        endif
        try
            let cmd = printf('%s --git-dir="%s" rev-parse --show-toplevel', g:committia#git#cmd, escape(git_dir, '\'))
            let out = s:system(cmd)
        finally
            if cwd_saved !=# getcwd()
                execute 'lcd' cwd_saved
            endif
        endtry

        let work_tree = trim(s:extract_first_line(out))
        return [git_dir, work_tree]
    endif

    if s:is_absolute_path($GIT_DIR) && isdirectory($GIT_DIR)
        let git_dir = $GIT_DIR
    else
        let root = s:extract_first_line(s:system(g:committia#git#cmd . ' rev-parse --show-cdup'))

        let git_dir = root . $GIT_DIR
        if !isdirectory(git_dir)
            throw 'Failed to get git-dir from $GIT_DIR'
        endif
    endif

    return [git_dir, fnamemodify(git_dir, ':h')]
endfunction

function! s:execute_git(cmd) abort
    let l:shellslash = &shellslash
    try
        set shellslash
        let [git_dir, work_tree] = s:search_git_dir_and_work_tree()
    catch
        throw 'committia: git: Failed to retrieve git-dir or work-tree: ' . v:exception
    finally
        let &shellslash = l:shellslash
    endtry

    if git_dir ==# '' || work_tree ==# ''
        throw 'committia: git: Failed to retrieve git-dir or work-tree'
    endif

    let index_file_was_set = s:ensure_index_file(git_dir)
    try
        let cmd = printf('%s --git-dir="%s" --work-tree="%s" %s', g:committia#git#cmd, escape(git_dir, '\'), escape(work_tree, '\'), a:cmd)
        try
            return s:system(cmd)
        catch
            throw 'committia: git: ' . v:exception
        endtry
    finally
        if index_file_was_set
            call s:unset_index_file()
        endif
    endtry
endfunction

function! s:ensure_index_file(git_dir) abort
    if $GIT_INDEX_FILE !=# ''
        return 0
    endif

    let lock_file = s:PATH_SEP . 'index.lock'
    if filereadable(lock_file)
        let $GIT_INDEX_FILE = lock_file
    else
        let $GIT_INDEX_FILE = a:git_dir . s:PATH_SEP . 'index'
    endif

    return 1
endfunction

function! s:unset_index_file() abort
    unlet $GIT_INDEX_FILE
endfunction

function! committia#git#diff() abort
    if g:committia#git#use_verbose
        let line = s:diff_start_line()
        if line > 0
            return getline(line, '$')
        endif
    endif

    let diff = s:execute_git(g:committia#git#diff_cmd)

    if diff !=# ''
        return split(diff, '\n')
    endif

    let line = s:diff_start_line()
    if line == 0
        return ['']
    endif

    " Fugly hack to tell committia#git#status() to get the status from the
    " commit message template too, otherwise status may not match with diff
    " Could be removed if g:committia#git#use_verbose was enabled by default
    let s:use_verbose_status = 1

    return getline(line, '$')
endfunction

function! s:diff_start_line() abort
    let re_start_diff_line = '^[#;@!$%^&|:] -\+ >8 -\+\n\%([#;@!$%^&|:].*\n\)\+diff --git'
    return search(re_start_diff_line, 'cenW')
endfunction

function! s:comment_char() abort
    let line = s:diff_start_line()
    if line == 0
        let line = line('$') + 1
    endif
    if getline(line - 1) =~# '^[#;@!$%^&|:]'
        return getline(line - 1)[0]
    else
        return '#'
    endif
endfunction

function! committia#git#status() abort
    try
        let status = s:execute_git(g:committia#git#status_cmd)
    catch /^committia: git: Failed to retrieve git-dir or work-tree/
        " Leave status window empty when git-dir or work-tree not found
        return ''
    endtry

    if g:committia#git#use_verbose || exists('s:use_verbose_status')
        if exists('s:use_verbose_status')
            unlet s:use_verbose_status
        end
        let scissors_line = search('^[#;@!$%^&|:] -\+ >8 -\+\n', 'cenW')
        if scissors_line > 1
            " Localisation hack, find the start of the status in the commit
            " message template using the first line of output from `git status`
            " Search backwards to avoid match in message, and start search at
            " scissors line to avoid potential match in diff, unlikely, but...
            let comment_char = getline(scissors_line)[0]
            let status_start_line = comment_char . ' ' . split(status, '\n')[0]
            let status_start = scissors_line
            while status_start > 1
                if getline(status_start - 1) ==# status_start_line
                    break
                endif
                let status_start -= 1
            endwhile
            if status_start > 1 && status_start < scissors_line
                return getline(status_start, scissors_line-1)
            endif
        endif
    endif

    let prefix = (exists('l:comment_char') ? comment_char : s:comment_char()) . ' '
    return map(split(status, '\n'), 'substitute(v:val, "^", prefix, "g")')
endfunction

function! committia#git#end_of_edit_region_line() abort
    let line = s:diff_start_line()
    if line == 0
        " If diff is not contained, assumes that the buffer ends with comment
        " block which was automatically inserted by Git.
        " Only the comment block will be removed from edit buffer. (#41)
        let line = line('$') + 1
    endif
    while line > 1
        if stridx(getline(line - 1), s:comment_char()) != 0
            break
        endif
        let line -= 1
    endwhile
    if line > 1 && empty(getline(line - 1))
        " Drop empty line before comment block.
        let line -= 1
    endif
    return line
endfunction
