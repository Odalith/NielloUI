// The API reference pages are generated (tools/docgen) from the doc comments
// in the source, so mdBook's "Suggest an edit" link would open a file that
// is not in the repository. On those pages, point it at the package's source
// instead, where the comments live.
(function () {
	var link = document.querySelector('a[rel="edit"]');
	if (!link) {
		return;
	}
	var m = link.href.match(/^(.*)\/edit\/([^/]+)\/docs\/src\/reference\/([a-z_]+)\.md$/);
	if (!m) {
		return;
	}
	var dir = m[3] === "niello" ? "niello" : "niello/" + m[3];
	link.href = m[1] + "/tree/" + m[2] + "/" + dir;
	link.title = "Edit the doc comments in " + dir;
	link.setAttribute("aria-label", link.title);
})();
