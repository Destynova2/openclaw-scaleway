variable "zone" {
  description = "Zone DNS (nom de domaine, ex: example.com)"
  type        = string
}

variable "records" {
  description = "Map de records DNS a creer"
  type = map(object({
    name = string
    type = string
    data = string
    ttl  = optional(number, 300)
  }))
}
