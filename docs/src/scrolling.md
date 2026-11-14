# Scrolling, sections and virtual lists

> This chapter is being written.

Scrollers, smooth scrolling and overscroll, deferred sections (begin_section) and niello/virtual's fixed and estimated lists.

To bring an item into view, an item just added included, use [`scroll_into_view`](reference/niello.md#scroll_into_view): it scrolls every scroller holding the item just far enough, against the frame's own layout. [`scroll_to`](reference/niello.md#scroll_to) sets an offset, clamped to the range as of the last frame.
