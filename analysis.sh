#!/usr/bin/env bash

run_evaluate() {

    exclude_path="repo/.DOCER_exclude"

    # List of regular expressions to match code elements
    regex_path="tool/regex_list.txt"

    # Create output directory
    mkdir -p output

    export regex_path

    # Set directories for the current repository
    repo_dir="repo"
    wiki_dir="wiki"

    # Print headers for the CSV output files
    printf '%s\n' "page_id,rev_id,code_element,count" > "output/matches.csv"
    printf '%s\n' "page_id,rev_id,code_element,file_name,line_number" > "output/sources.csv"
    printf '%s\n' "page_id,page_type,page_name" > "output/pages.csv"
    printf '%s\n' "page_id,rev_id,rev_SHA,rev_timestamp,doc_SHA,doc_timestamp" > "output/revisions.csv"

    export repo_name
    export repo_dir
    export wiki_dir

    while IFS= read -r -d $'\0' page; do
        evaluate_page "$page"
    done < <({

        # Find README.md in the source code repository
        awk 'BEGIN { RS="\0"; ORS="\0" }; { print 0, $0 }' <(
            grep -axzF README.md <( # Match README.md in the root directory
                sort -z <( # Sort page names
                    find "$repo_dir" -type f -printf '%P\0' 2> /dev/null
                )
            )
        );

        # Find documentation files in the wiki repository
        awk 'BEGIN { RS="\0"; ORS="\0" }; { print NR, $0 }' <(
            grep -aivzE "(^|\/)_[^\/]*\." <( # Match file names that do not start with '_'
                # Match a list of valid markup extensions: https://github.com/github/markup#markups
                grep -aizP "\.(markdown|mdown|mkdn|md|textile|rdoc|org|creole|mediawiki|wiki|rst|asciidoc|adoc|asc|pod)$" <(
                    sort -z <( # Sort page names
                        find "$wiki_dir" -type f -printf '%P\0' 2> /dev/null
                    )
                )
            )
        );
    })
}

evaluate_page() {

    IFS=' ' read -r -d $'\0' page_id page_name < <(printf '%s\0' "$1")

    # Set the directory to the page location
    if ((page_id == 0)); then
        page_dir="$repo_dir"
    else
        page_dir="$wiki_dir"
    fi

    printf '%s,%s,"%s"\n' "$page_id" "${page_dir##*/}" "${page_name//\"/\"\"}" >> "output/pages.csv"

    # Get when the page was last updated
    snapshot_timestamp="$(git -C "$page_dir" log -1 --first-parent --pretty=format:%ct HEAD -- "$page_name")"
    snapshot_SHA="$(tail -1 <(git -C "$repo_dir" rev-list --max-age="$snapshot_timestamp" --first-parent HEAD 2> /dev/null))"

    export page_id
    export page_dir
    export page_name

    if ((${#snapshot_SHA})); then
        # Compare the snapshot and the latest revision
        while IFS= read -r revision; do
            evaluate_revision "$revision"
        done < <(
            awk '{ print NR, $0 }' <({
                printf '%s\n' "$snapshot_SHA";
                git -C "$repo_dir" rev-list -1 --first-parent HEAD 2> /dev/null;
            })
        )
    else
        # Page was updated after the latest revision,
        # set the snapshot to the latest revision
        while IFS= read -r revision; do
            evaluate_revision "$revision"
        done < <(
            awk '{ print NR, $0 }' <({
                git -C "$repo_dir" rev-list -1 --first-parent HEAD 2> /dev/null;
                git -C "$repo_dir" rev-list -1 --first-parent HEAD 2> /dev/null;
            })
        )
    fi
}

evaluate_revision() {

    read -r rev_id rev_SHA < <(printf '%s' "$1")

    rev_timestamp="$(git -C "$repo_dir" log -1 --first-parent --pretty=format:%ct "$rev_SHA")"
    doc_SHA="$(git -C "$page_dir" rev-list -1 --min-age="$rev_timestamp" --first-parent HEAD -- "./$page_name")"

    # Return early if documentation SHA is not found
    if ((!${#doc_SHA})); then return; fi

    doc_timestamp="$(git -C "$page_dir" log -1 --first-parent --pretty=format:%ct "$doc_SHA")"
    page_found="$(git -C "$page_dir" ls-tree "$doc_SHA" --name-only "./$page_name")"

    # Return early if page is not found
    if ((!${#page_found})); then return; fi

    printf '%s,%s,%s,%s,%s,%s\n' "$page_id" "$rev_id" "$rev_SHA" "$rev_timestamp" "$doc_SHA" "$doc_timestamp" >> "output/revisions.csv"

    # List of file names found in this revision
    file_names="$(
        tr '\0' '\n' < <( # Change delimiter from '\0' to '\n'
            sed -nz '/\n/!p' <( # Remove names containing newline
                sort -uz <(
                    git -C "$repo_dir" ls-tree -rz "$rev_SHA" --name-only;
                )
            )
        )
    )"

    # List of unique code elements in the current documentation page
    # that match the list of regular expressions provided
    code_elements="$(
        grep -vxF -f <(cat "$exclude_path" 2> /dev/null) <(
            sort -u <(
                git -C "$page_dir" grep -howIP -f "$PWD/$regex_path" "$doc_SHA" -- "./$page_name"
            )
        )
    )"

    # List of code elements in the repository (excluding ./README.md)
    # that match the code elements found in the documentation and file names
    matched_elements="$(
        sort <({
            # Search for code elements in the documentation
            git -C "$repo_dir" grep -howFI -f <(printf '%s' "$code_elements") "$rev_SHA" -- ':!./README.md';

            # Intersection of code elements and file names
            grep -xF -f <(printf '%s' "$code_elements") <(
                sed -r 's/(.*)/\/\1\n\1/g' <( # Duplicate path and prepend '/'
                    # Recursively get subpaths (path/to/file -> to/file -> file)
                    while ((${#file_names})); do
                        # Remove empty lines and print the file names
                        grep -v '^$' <(printf '%s' "$file_names")
                        file_names="$(
                            # Remove first part of the path component
                            sed -r 's/[^\/]*(\/|$)//' <(printf '%s' "$file_names")
                        )"
                    done
                )
            );
        })
    )"

    # Extract source information of code elements
    while IFS=: read -r -d '' SHA file_name; read -d '' line_number; read -r code_element; do
        printf '%s,%s,"%s","%s",%s\n' "$page_id" "$rev_id" "${code_element//\"/\"\"}" "${file_name//\"/\"\"}" "$line_number"
    done < <(
        git -C "$repo_dir" grep -aznowFI -f <(printf '%s' "$code_elements") "$rev_SHA" -- ':!./README.md'
    ) >> "output/sources.csv"

    # List of code elements that are not matched
    while read -r code_element; do
        printf '%s,%s,"%s",0\n' "$page_id" "$rev_id" "${code_element//\"/\"\"}"
    done < <(
        # Subtraction of matched elements from code elements
        grep -vxF -f <(printf '%s' "$matched_elements") <(printf '%s' "$code_elements")
    ) >> "output/matches.csv"

    # List of code elements that are matched
    while read -r count code_element; do
        printf '%s,%s,"%s",%s\n' "$page_id" "$rev_id" "${code_element//\"/\"\"}" "$count"
    done < <(
        # Count the occurrences of matched elements
        uniq -c <(printf '%s' "$matched_elements")
    ) >> "output/matches.csv"
}

export -f evaluate_page
export -f evaluate_revision

run_evaluate
