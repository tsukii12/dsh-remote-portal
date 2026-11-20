// `?bare=1`: the model alone on a see-through page, without her room (the
// tavern's visual novel draws its own scene behind). Set before the page draws,
// so the room never shows; stage.css does the rest.
if (new URLSearchParams(location.search).get('bare') === '1') document.documentElement.dataset.bare = '1';
