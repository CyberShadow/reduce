<!-- This file is best viewed on https://github.com/CyberShadow/reduce#readme. Apologies for all the HTML! -->
<a href="https://github.com/CyberShadow/reduce/actions/workflows/test.yml"><img align="right" src="https://github.com/CyberShadow/reduce/actions/workflows/test.yml/badge.svg?branch=master" alt="test" /></a><a href="https://codecov.io/gh/CyberShadow/reduce"><img align="right" src="https://codecov.io/gh/CyberShadow/reduce/branch/master/graph/badge.svg?token=CxoRmYgdJp" alt="codecov" /></a>
reduce
======

<img align="right" src="https://dump.thecybershadow.net/6b58560174d8f1f5c0d15315fe6ab021/anim.svgz">

`reduce` is a general-purpose data reduction tool. 
Given a dataset (in one or more files), it *reduces* it to a minimal variation 
which still satisfies some condition specified by you.

To make this work, two mechanisms are needed:

1. A syntax parser, which splits the input into a hierarchy which can be reduced piecewise.
   `reduce` includes implementations for general and some common formats, and can utilize external implementations.

2. An oracle, which tests whether a variation of the dataset still satisfies the desired condition.
   The oracle is specified as a shell command or script on the command line, along with the input dataset.

After parsing the input, `reduce` successively attempts to remove fragments of the dataset, 
asking the oracle after each attempt whether the condition still holds. 
After walking the entire hierarchy, it produces the reduced dataset.


Example applications
--------------------

- <details><summary>Reduce a large program which triggers some compiler bug to a minimal test case</summary><p></p>

  This is the original and most common application, and the one targeted by similar tools 
  such as [creduce](https://embed.cs.utah.edu/creduce/) and [bugpoint](https://llvm.org/docs/CommandGuide/bugpoint.html).

  If your compiler is called `gcc`, and it is crashing with the error message `internal compiler error`, 
  a typical invocation would be:

      reduce program.c 'gcc program.c 2>&1 | grep "internal compiler error"'
  </details>

- <details><summary>Narrow down the cause of a confusing error message</summary><p></p>

  Consider the situation: after making some changes to some code, the tool (compiler) 
  produces only the error message `failed to frobnicate whatsits`, and refuses to elaborate further.
  You have no idea what frobnication or whatsits are, and you certainly don't knowingly use any of these things in your code, 
  thus having no obvious way to proceed in debugging the problem.

  `reduce` can be used to narrow down your code to the minimal variation which still causes the error message.
  As the result of this reduction will have all extraneous parts (which are not necessary for the error message to manifest) removed,
  it is likely to make it clearer what causes the whatsits to get frobnicated, and perhaps even why said action fails.

  The would-be invocation is similar to the above:

      reduce input.foo 'foo-tool input.foo 2>&1 | grep "failed to frobnicate whatsits"'
  </details>

- <details><summary>Reduce a large Git commit to a minimal diff</summary><p></p>

  You may be familiar with `git bisect run`, a Git feature used to automatically bisect (narrow down) regressions.
  It allows specifying a condition, which Git will use to find the earliest commit which satisfies said condition.
  However, as not everyone employs the practice of atomic git commits, 
  sometimes the identified commit is still too large to clearly demonstrate the cause of the regression.

  `reduce` can be used to continue where `git bisect run` finished:

  1. Export the commit to a `.diff` file:

         git -C /path/to/repo show badcommitsha1 > commit.patch

  2. Reset the repository to the bad commit's parent:

         git -C /path/to/repo reset --hard badcommitsha1^

  3. Create `oracle.sh`, the test script:

     ```bash
     #!/bin/bash
     set -eu

     git clone --depth=1 /path/to/repo repo
     cd repo
     patch -p 1 ../commit.patch
     ./configure && make
     # Place your test command here.
     # It should be the same as "git bisect run", but invert the exit code.
     ./check-if-bug-exists
     ```

  4. Make it executable (`chmod +x oracle.sh`).

  5. Invoke `reduce` as:

         reduce commit.patch -f oracle.sh
  </details>

- <details><summary>Reduce a Git commit set</summary><p></p>

  This application also follows `git bisect run`.
  Consider the situation where the first commit in which a bug manifests only exposes a latent bug, 
  and does not actually contain the faulty code, 
  or any other variation where the bug is effected by the "joint effort" of changes across multiple commits.

  The sought information is thus not a single commit, but the minimal set of commits 
  (starting from some base) which satisfy the given condition.

  `reduce` can be used to produce this minimal set as follows:

  1. Export the list of commits to a text file:

         git -C /path/to/repo log --pretty=%H basecommitsha1.. > commits.txt

  2. Reset the repository to the base commit:

         git -C /path/to/repo reset --hard basecommitsha1

  3. Create `oracle.sh`, the test script:

     ```bash
     #!/bin/bash
     set -eu

     git clone /path/to/repo repo
     cd repo
     git cherry-pick $(cat ../commits.txt)
     ./configure && make
     # Place your test command here.
     # It should be the same as "git bisect run", but invert the exit code.
     ./check-if-bug-exists
     ```

  4. Make it executable (`chmod +x oracle.sh`).

  5. Invoke `reduce` as:

         reduce commits.txt --syntax=lines -f oracle.sh
  </details>

- <details><summary>Obfuscate proprietary code before posting it online</summary><p></p>

  Occasionally, you may need to share some proprietary code with a compiler developer in order for them to be able to reproduce a bug.
  Publishing the code verbatim may be out of the question, so it would first need to be mangled to obscure its intent.

  `reduce` has an alternate mode which can aid in this task. 
  If `--obfuscate` is specified, it switches its default mode (reduction) to obfuscation.
  The basic principle remains the same; what changes is the kind of modification that `reduce` tries to do:
  instead of deleting parts of the input, it attempts to rename each word / identifier,
  only keeping those renames which cause the test condition to hold.

  A typical invocation would thus be:

      reduce --obfuscate program.c 'gcc program.c 2>&1 | grep "internal compiler error"'
  </details>


Basic usage
-----------

- <details><summary>Reduce a file</summary><p></p>

  <pre>reduce <i>FILE</i> <i>ORACLE</i></pre>

  *`ORACLE`* is a shell command, which should return 0 if the *`FILE`* variation in the current directory 
  is a good reduction (continues holding the desired properties), or non-zero otherwise.
  It is expected to return 0 if *`FILE`* is provided with no modifications.

  A common simple oracle is `some-compiler FILE 2>&1 | grep "some error message"`.
  The exit status of a shell pipeline is that of the last command (here, `grep`),
  and `grep` exits with status 0 if the indicated string is found 
  (which indicates to `reduce` that this is a good reduction).

  `reduce` always creates temporary directories in which it places (modified) copies of *`FILE`* before executing the oracle.
  Thus, the oracle command always runs in a temporary directory holding a different version of the file every time; 
  it should therefore not make any assumptions about the current directory, other than that it holds a copy of the *`FILE`* to test.

  The final result of the reduction will by default be saved to <code><i>FILE</i>.result/<i>FILE</i></code>.
  </details>

- <details><summary>Reduce a directory</summary><p></p>

  <pre>reduce <i>DIRECTORY</i> <i>ORACLE</i></pre>

  Same as above, except *`ORACLE`* is executed in (modified) copies of the directory.

  The final result of the reduction will by default be saved to <code><i>DIRECTORY</i>.result</code>.
  </details>

- <details><summary>Reduce using a test script</summary><p></p>

  If the oracle shell command is too long to be expressed on `reduce`'s command line, a shell script can be used instead:

  <pre>reduce <i>FILE</i> -f <i>ORACLE-FILE</i></pre>

  This is the same as above, except *`ORACLE-FILE`* is a file instead of a shell command.

  This invocation is equivalent to <code>reduce <i>FILE</i> "$PWD/<i>ORACLE-FILE</i>"</code>.
  </details>

- <details><summary>Reduce from standard input</summary><p></p>

  <pre>... | reduce - --syntax=<i>SYNTAX</i> <i>ORACLE</i>  | ...</pre>

  *`SYNTAX`* should specify the syntax that the input is in.

  In this mode, *`ORACLE`* should read the dataset to test from standard input as well.
  A temporary directory will still be created, so it is safe for it to create temporary files.

  `reduce` will by default produce the final result of the reduction on its standard output.
  </details>

Run `reduce --help` for all options.  
Additional documentation and examples can be found on [the GitHub wiki](https://github.com/CyberShadow/reduce/wiki).


Installation
------------

`reduce` can be installed in one of the following ways:

- An [AUR package is available](https://aur.archlinux.org/packages/reduce) for Arch Linux and derivatives.
- Download a static binary from [the releases page](https://github.com/CyberShadow/reduce/releases)
  or [the latest CI run](https://github.com/CyberShadow/reduce/actions?query=branch%3Amaster).
- Clone this repository and build from source (see below).


Building
--------

- Install [a D compiler](https://dlang.org/download.html)
- Install [Dub](https://github.com/dlang/dub), if it wasn't included with your D compiler
- Run `dub build -b release`


License
-------

`reduce` was created by Vladimir Panteleev and [contributors](https://github.com/CyberShadow/reduce/graphs/contributors),
and is distributed under the Boost Software Licence, version 1.0.
