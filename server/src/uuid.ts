const nilUuid = '00000000-0000-0000-0000-000000000000';
const maxUuid = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
const rfc9562UuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isValidUuid(value: string): boolean {
  const normalized = value.toLowerCase();
  return (
    normalized === nilUuid ||
    normalized === maxUuid ||
    rfc9562UuidPattern.test(value)
  );
}
