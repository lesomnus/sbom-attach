# One CycloneDX document out of several: the build's (zero or more) and the
# image's (last). Run with `jq -s --arg serial urn:uuid:… -f merge.jq build… image`.
#
# Each sees what the others cannot. A build's knows what was put in -- a
# lockfile's packages, which a bundler then folds into one file no scan of the
# image can take apart; licenses that live in a module cache and not in the
# image. The image's knows what is actually there -- the base's packages, and
# whatever else ended up in it.
#
# A component more than one names is written once. Two are the same when their
# purls are, less the qualifiers (`?arch=…`, `?type=module`), which different
# scans do not agree on; one with no purl -- a file, the operating system -- is
# known by its type and name. Of those, the one carrying the most licenses is
# kept, and on a tie the earliest: a build's before the image's.
#
# The rest of the document is the image's: its `metadata.component` is the
# image, which is what the result describes. It gets the serial number it is
# given -- it is none of the documents it was made from -- and no dependency
# graph, since the components the graph would name are now partly other
# documents', whose `bom-ref`s it does not use.

def key: (.purl // "") as $p
	| if $p != "" then ($p | sub("\\?.*$"; ""))
	  else "nopurl:" + (.type // "") + ":" + (.name // "") end;
def nlicenses: (.licenses // []) | length;

. as $docs
| $docs[-1] as $image
| ([$docs[] | .components[]?]
   | reduce .[] as $c ({order: [], kept: {}};
       ($c | key) as $k
       | if .kept[$k] == null then .order += [$k] | .kept[$k] = $c
         elif ($c | nlicenses) > (.kept[$k] | nlicenses) then .kept[$k] = $c
         else . end)
   | . as $s | [$s.order[] | $s.kept[.]]) as $components
| $image
| .components = $components
| .serialNumber = $serial
| .version = 1
| del(.dependencies)
| .metadata.tools.components = ([$docs[] | .metadata.tools.components[]?]
                                 | unique_by((.name // "") + "@" + (.version // "")))
