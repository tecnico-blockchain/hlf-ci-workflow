export class URLS {
    // private static IP = "http://localhost:8080/";
    private static IP = process.env['API_ENDPOINT'] || "https://restapi.localho.st/";
    public static LIST = URLS.IP + "list";
    public static CREATE = URLS.IP + "create";
    public static UPDATE = URLS.IP + "update";
    public static DELETE = URLS.IP + "delete";
}
