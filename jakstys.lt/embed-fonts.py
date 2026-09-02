import base64, io, pathlib, sys
from html.parser import HTMLParser
from fontTools import subset, ttLib

class Text(HTMLParser):
    void = set("area base br col embed hr img input link meta param source track wbr".split())
    def __init__(self):
        super().__init__()
        self.stack = [None]
        self.chars = {x: set() for x in ("caps", "regular")}
    def handle_starttag(self, tag, attrs):
        face = dict(attrs).get("data-font", self.stack[-1])
        if tag not in self.void: self.stack.append(face)
    def handle_endtag(self, tag):
        if tag not in self.void: self.stack.pop()
    def handle_data(self, data):
        if self.stack[-1]: self.chars[self.stack[-1]].update(c for c in data if not c.isspace())

def encode(path, text):
    options = subset.Options(flavor="woff2", desubroutinize=True, layout_features=["kern", "liga"])
    font = ttLib.TTFont(path, recalcBBoxes=True, recalcTimestamp=True)
    slimmer = subset.Subsetter(options=options)
    slimmer.populate(text="".join(sorted(text)))
    slimmer.subset(font)
    actual = set().union(*(set(x.cmap) for x in font["cmap"].tables))
    assert actual == set(map(ord, text))
    output = io.BytesIO()
    font.save(output)
    return "data:font/woff2;base64," + base64.b64encode(output.getvalue()).decode()

source, caps, regular, target = map(pathlib.Path, sys.argv[1:])
html = source.read_text()
parser = Text()
parser.feed(html)
assert all(parser.chars.values())
for name, path in (("caps", caps), ("regular", regular)):
    placeholder = f"@valkyrie-{name}@"
    assert html.count(placeholder) == 1
    html = html.replace(placeholder, encode(path, parser.chars[name]))
target.write_text(html)
