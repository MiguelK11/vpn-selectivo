// VPN Selectivo — convierte la lista pública de servidores WireGuard de Mullvad
// (https://api.mullvad.net/public/relays/wireguard/v2/) en TSV:
//   host  ubicación  país  ciudad  activo  en_país  peso  ipv4  clave_pública
// vsctl valida después cada campo; aquí solo se quitan caracteres de control.
// uso: osascript -l JavaScript relays2tsv.js <archivo.json>
function run(argv) {
    ObjC.import('Foundation');
    var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    var d = JSON.parse(ObjC.unwrap(s));
    var clean = function (x) { return String(x).replace(/[\u0000-\u001f\u007f\\"'<>&|;$`]/g, ' ').trim(); };
    var out = [];
    (d.wireguard.relays || []).forEach(function (r) {
        var l = (d.locations || {})[r.location] || {};
        out.push([clean(r.hostname), clean(r.location), clean(l.country || ''), clean(l.city || ''),
                  r.active ? 1 : 0, r.include_in_country ? 1 : 0, (r.weight | 0),
                  clean(r.ipv4_addr_in), clean(r.public_key)].join('\t'));
    });
    return out.join('\n');
}
